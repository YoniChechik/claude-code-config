# Feature: Multi-Session Hook Script Fixes

## TLDR

Two Claude Code windows on the same branch (or just both on `main`) silently
corrupt each other's `/tmp/ci_watch_*` state, leak watchers, and produce
mis-routed notifications. We introduce a per-session identity primitive
(`session_id` from the hook payload, bridged via a clone-local token file
written at SessionStart) and rewrite every `/tmp` filename to be keyed by
`(branch, session)`. We also fix a pile of latent shell bugs surfaced while
auditing the same scripts: `set -e` + command-substitution traps, JSON parse
error handling, lock-file PID reuse, transcript-scan misses, atomic cache
writes, and a Python string-injection in `stop_failure__rate_limit.sh`.

## Research and References

### Files audited

- `/Users/yonichechik/.claude/scripts/ci_watch_persistent.sh` — the watcher.
  Detached process. Launched from `/ci` skill via shell backgrounding;
  does NOT receive a hook stdin payload. Gets `PORT`, `BRANCH`,
  `SESSION_TOKEN` as argv from the skill (where `SESSION_TOKEN` is the
  webhook MCP's UUID, not the Claude session_id).
- `/Users/yonichechik/.claude/scripts/status_line.sh` — runs once per
  refresh. RECEIVES JSON on stdin (workspace, context_window, rate_limits)
  but the payload does NOT include `session_id`. Reads `/tmp/ci_watch_*`.
- `/Users/yonichechik/.claude/scripts/stop__sound.sh` — Stop hook. Receives
  full hook JSON on stdin including `session_id` and `transcript_path`.
- `/Users/yonichechik/.claude/scripts/session_start.sh` — SessionStart hook.
  Receives `session_id` on stdin (per docs/multi-session-architecture.md
  line 63: "Every hook receives a JSON payload on stdin that includes
  `session_id`, `cwd`, `tool_name`, and `tool_input`"). Currently does not
  read it.
- `/Users/yonichechik/.claude/scripts/stop_failure__rate_limit.sh` —
  StopFailure hook. Has a Python heredoc that interpolates `$CLAUDE_JSON`
  into Python source (path-injection risk if `$HOME` is exotic).
- `/Users/yonichechik/.claude/scripts/notification__sound.sh`,
  `notify_waiting.sh` — sound + tab-title hooks. Already use `/dev/tty`
  for routing, so per-tty isolation handles them. Only minor issues
  (blocking `afplay`, no `command -v` guard).
- `/Users/yonichechik/.claude/settings.json` — hook registrations.
- `/Users/yonichechik/.claude/docs/multi-session-architecture.md` — exists,
  documents current state including all known gaps. Confirms `session_id`
  is on every hook stdin payload.
- `/Users/yonichechik/.claude/channel/webhook.ts` — MCP webhook server.
  Mints `sessionToken = randomUUID()` at startup; `get_port` tool returns
  `${httpPort}:${sessionToken}`. This token is per-MCP-process, NOT the
  Claude session UUID — different concept.
- `/Users/yonichechik/.claude/skills/ci/SKILL.md` — `/ci` invocation.

### Session identity options evaluated

| Option                                                                                                      | Evaluation                                                                                                                                                                                                                                                                                                                                                                                                                                            |
|-------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **A.** `$CLAUDE_SESSION_ID` env var                                                                         | Not present. `grep -rn 'CLAUDE_SESSION'` in scripts/docs returns nothing. Not exposed by harness.                                                                                                                                                                                                                                                                                                                                                     |
| **B.** Webhook TOKEN written by `session_start.sh`, read via parent PID                                     | Webhook TOKEN is per-MCP-server, not per-Claude-session. SessionStart hook also can't easily get the webhook port without an MCP call.                                                                                                                                                                                                                                                                                                                |
| **C.** Clone-local token file written by `session_start.sh`, hooks read via `git rev-parse --show-toplevel` | Workable for hooks running inside the clone. But (1) two windows on the same clone overwrite each other's token; (2) status_line.sh can resolve clone root, but the watcher and hooks see only their own cwd. Not a clean primitive.                                                                                                                                                                                                                  |
| **D.** Parent PID of hook process                                                                           | The hook's parent IS the Claude Code process — stable for a session's lifetime, unique across windows. But this is the OS PID of the harness, which we can read via `ps -o ppid=` from inside any hook. Reliable, no setup. Drawback: if Claude Code spawns hooks via an intermediate shell, the parent PID may not be the Claude process.                                                                                                            |
| **E.** Hook payload `session_id` (UUID)                                                                     | Already on stdin for every hook. 36 chars — too long for `/tmp` filenames as-is, but the first 8 chars of the UUID are uniquely sufficient (collision probability negligible across the handful of concurrent sessions a user has). Zero MCP calls. Works in every hook context. Drawback: status_line.sh's stdin payload does NOT contain `session_id` (only workspace/context_window), and ci_watch_persistent.sh receives no stdin payload at all. |

### Chosen approach

**Hybrid (E + C):** Hook payload `session_id` is the source of truth. We
shorten it to its first 8 hex chars (`SID8 = ${session_id:0:8}`) and use
`(branch, SID8)` as the `/tmp` namespace key. For the two contexts that
do NOT receive `session_id` on stdin — `status_line.sh` and
`ci_watch_persistent.sh` — `session_start.sh` writes a small
session-discovery file:

```
~/.claude/session-env/<sessionId>/
    sid8            # 8-char short id
    cwd             # session cwd at start
    branch          # branch at start
```

Plus a `cwd → sid8` reverse lookup at a per-cwd path:

```
~/.claude/cache/cwd-session/<sha1(cwd)>   # contains sid8
```

`status_line.sh` reads its sid8 from `~/.claude/cache/cwd-session/<sha1(cwd)>`.
`ci_watch_persistent.sh` receives sid8 as a NEW 4th argv argument from the
`/ci` skill (which already has access to it via the SessionStart-written
file — the skill resolves cwd → sid8 the same way).

**Why this works:**

1. Simple: hooks that have `session_id` on stdin use it directly; the two
   that don't have a single well-defined fallback path.
2. Reliable: SessionStart fires once at start, writes both files
   atomically (mktemp + mv), and the cwd-keyed file is overwritten if
   another session opens in the same cwd (last-writer-wins, which is
   correct — the new session is the live one).
3. No MCP calls: pure filesystem reads.
4. Works across all hook types.

**Drawbacks accepted:**

- Two simultaneous sessions in the same cwd (which the workflow
  explicitly discourages) will contend on the cwd→sid8 file. We treat
  this as out-of-scope; the cwd→sid8 file is purely a discoverability
  hint for status_line.
- 8 hex chars = 16^8 ≈ 4.3B possibilities. Birthday collision at 65k
  concurrent sessions, which is irrelevant.

## Session Identity Solution

**Primitive:** `SID8 = first 8 hex chars of payload session_id`. All
`/tmp` filenames key on `(BRANCH_KEY, SID8)`:

```
/tmp/ci_watch_state_${BRANCH_KEY}_${SID8}
/tmp/ci_watch_lock_${BRANCH_KEY}_${SID8}
/tmp/ci_watch_pr_${BRANCH_KEY}_${SID8}
/tmp/ci_watch_${BRANCH_KEY}_${SID8}.log
```

where `BRANCH_KEY="${BRANCH//\//__}"` (slash-sanitized).

**Discovery for hooks without session_id on stdin:** read
`~/.claude/cache/cwd-session/$(printf '%s' "$cwd" | shasum -a 1 | cut -c1-12)`,
which `session_start.sh` populates.

### Task 0: Establish Session Identity Primitive

**What:**

- In `session_start.sh`, before the existing logic, read stdin once into
  `INPUT`, extract `session_id` via `jq -r .session_id`, compute
  `SID8="${session_id:0:8}"`. If empty/null, fall back to `unknown` — log
  a warning to `~/.claude/logs/session_start.log` so we can detect
  harness changes.
- Compute `cwd_hash=$(printf '%s' "$PWD" | shasum -a 1 | cut -c1-12)`.
- `mkdir -p ~/.claude/cache/cwd-session ~/.claude/session-env/$session_id`.
- Atomically write `~/.claude/cache/cwd-session/$cwd_hash` and
  `~/.claude/session-env/$session_id/sid8` using `mktemp + mv`.
- Add a tiny shared helper `~/.claude/scripts/lib/session_id.sh` exporting
  two functions:
  - `sid8_from_payload <json>` — `jq -r .session_id` then cut to 8 chars.
  - `sid8_from_cwd <cwd>` — sha1+cut, then read cache file. Echoes empty
    string on miss.
- Update `/Users/yonichechik/.claude/skills/ci/SKILL.md`: after parsing
  branch, also resolve `SID8` via `sid8_from_cwd "$PWD"` and pass as the
  4th argument to the watcher.

### Task 1: Branch-name sanitization (BRANCH_KEY)

**What:**

- In `ci_watch_persistent.sh`: add `BRANCH_KEY="${BRANCH//\//__}"` near
  top, replace all `/tmp` path uses of `${BRANCH}` with `${BRANCH_KEY}`.
- In `status_line.sh`: same sanitization for cache file reads (build
  `branch_key="${branch//\//__}"`).
- In `skills/ci/SKILL.md`: replace `/tmp/ci_watch_${BRANCH}.log` with the
  sanitized form.

### Task 2: Session-scope state files in ci_watch_persistent.sh + status_line.sh

**What:**

- `ci_watch_persistent.sh`:
  - Accept new 4th argv `SID8` (required). Update usage string.
  - Define `SLOT="${BRANCH_KEY}_${SID8}"` and rewrite all `/tmp/ci_watch_*`
    paths to use `$SLOT`.
  - Update the lock-file logic (Task 6 will tighten it further).
- `status_line.sh`:
  - Resolve `SID8` via the cwd→session cache file using the dir field
    from its stdin payload. On miss, fall back to legacy
    `${branch}` filename for one release (read-only) so a status line
    started before the watcher is restarted still shows something.
  - Use `slot="${branch_key}_${sid8}"` for state/PR cache reads.
- `/ci` skill: pass `SID8` as 4th argv to the watcher launch line.

### Task 3: Fix `set -e` + command substitution in ci_watch_persistent.sh

**What:**

- `fetch_runs_for()`: replace
  ```bash
  output=$(gh run list ... 2>&1)
  exit_code=$?
  ```
  with
  ```bash
  if ! output=$(gh run list ... 2>&1); then
      echo "Warning: ..." >&2
      echo "[]"; return 0
  fi
  ```
  Under `set -e` an assigned-then-checked `$?` works only because the
  assignment is the last command, but it's brittle if anyone adds a
  pre-check log line. Inline `if !` is robust.
- Audit `detect_new_sha`, `get_sha_runs_for`, the merged-path block, and
  every `RUNS_JSON=$(...)` / `pr_checks_json=$(...)` for the same pattern.
- Replace any `local var=$(cmd)` (which masks `$?`) with declare-then-assign
  on two lines.

### Task 4: Fix stop__sound.sh agent ID tracking

**What:**

- Read a real transcript file and document the actual JSONL event shapes
  in a comment. Confirm the field names: is it `agentId` or
  `agent_id`? Is the completion delivered as `<task-id>` matching the
  `agentId`, or are these different namespaces?
- Update `extract_completed_ids` to match all terminal statuses by using
  a regex over the status field:
  `re.search(r"<status>(completed|failed|cancelled|error|timeout|aborted)</status>", text)`.
- If the launch records an `agentId` and the completion records a
  `<task-id>` that's actually the SAME id, keep set arithmetic. If they
  are different namespaces, look up the launch record's `taskId` /
  `task_id` instead, and compare to that.
- Add a debug log gated behind `CLAUDE_DEBUG_STOP=1` env var that prints
  the launched/completed sets when they don't match.

### Task 5: Fix status_line.sh JSON parse error handling

**What:**

- Replace
  ```bash
  while IFS= read ...; do fields+=("$line"); done < <(echo "$input" | jq ...)
  if [ $? -ne 0 ]; then ...
  ```
  with
  ```bash
  if ! parsed=$(echo "$input" | jq -r '...' 2>/dev/null); then
      printf '%b' "${red}(status_line.sh: json parse error)${reset}"
      exit 0
  fi
  IFS=$'\n' read -r -d '' -a fields <<< "$parsed" || true
  ```
  The current `$?` check sees the exit status of `read` (always 0 at EOF
  in the loop), not `jq`. The error path is effectively dead.

### Task 6: Fix PID reuse race in lock file

**What:**

- After `OLD_PID=$(cat "$LOCK_FILE")` and the existence check, validate
  the process is actually our watcher before killing it:
  ```bash
  if kill -0 "$OLD_PID" 2>/dev/null \
     && ps -p "$OLD_PID" -o args= 2>/dev/null | grep -q ci_watch_persistent; then
      kill "$OLD_PID" || true
      # Wait for it to actually exit, up to 10s, in 1s ticks (per CLAUDE.md
      # rule: no fixed sleeps, poll instead).
      for _ in 1 2 3 4 5 6 7 8 9 10; do
          kill -0 "$OLD_PID" 2>/dev/null || break
          sleep 1
      done
  fi
  ```
- Replace the existing `sleep 1` with the polling loop above.

### Task 7: Fix SHA_RUNS empty escalation

**What:**

- After `detect_new_sha` and `SHA_RUNS=$(get_sha_runs_for ...)`, when
  length is 0 on the BRANCH path (currently silent `continue`):
  - Track `SHA_RUNS_EMPTY_COUNT`. Increment when empty, reset to 0
    whenever we get a non-empty result.
  - When count reaches `SHA_RUNS_EMPTY_MAX=24` (≈2 minutes at 5s
    poll interval), fire a one-shot webhook:
    `"⚠️ No CI runs visible for ${BRANCH} after 2 min — workflow may be missing."`
    Set a `REPORTED_NO_RUNS` flag so we don't spam.
  - Reset `REPORTED_NO_RUNS` and `SHA_RUNS_EMPTY_COUNT` whenever a new
    SHA is detected (in `detect_new_sha`).

### Task 8: Fix empty RUNS_JSON crash

**What:**

- In `fetch_runs_for`, the `gh run list` success path can still yield a
  non-JSON string if the API returns 200 with HTML (rare, but possible
  during GitHub maintenance). Wrap the value through a `jq` validator:
  ```bash
  if ! echo "$output" | jq empty 2>/dev/null; then
      echo "[]"
      return 0
  fi
  ```
- Same guard inside the merged-path branch on `MAIN_RUNS_JSON`.
- Add a single line right before any `jq` use of `$RUNS_JSON`/`$SHA_RUNS`:
  `[ -z "$RUNS_JSON" ] && RUNS_JSON='[]'` (defensive, near-free).

### Task 9: Atomic PR cache writes

**What:**

- Replace
  ```bash
  printf '%s' "$PR_JSON" > "/tmp/ci_watch_pr_${SLOT}"
  ```
  with
  ```bash
  tmp=$(mktemp "/tmp/ci_watch_pr_${SLOT}.XXXXXX")
  printf '%s' "$PR_JSON" > "$tmp"
  mv -f "$tmp" "/tmp/ci_watch_pr_${SLOT}"
  ```
  so `status_line.sh` never reads a half-written file.
- Same pattern for `/tmp/ci_watch_state_${SLOT}` (state writes happen in
  multiple paths — define a small helper `write_state()`).

### Task 10: Fix stop_failure__rate_limit.sh path injection

**What:**

- Replace
  ```bash
  ORG_NAME=$(python3 -c "
  import json, sys
  d = json.load(open('$CLAUDE_JSON'))
  ...
  ")
  ```
  with env-var passing:
  ```bash
  ORG_NAME=$(CLAUDE_JSON="$CLAUDE_JSON" python3 - <<'PY' 2>/dev/null
  import json, os
  try:
      with open(os.environ["CLAUDE_JSON"]) as f:
          d = json.load(f)
      print(d.get("oauthAccount", {}).get("organizationName", ""))
  except Exception:
      print("")
  PY
  )
  ```
  Heredoc with `'PY'` (quoted) prevents shell expansion; env-var prevents
  injection if `$HOME` ever contains a `'`.

### Task 11: Fix session_start.sh issues

**What:**

- Remove the dead `json_escape()` function — its only caller was replaced
  by `jq -Rs .` on line 129, and the unconditional `printf` for the
  jq-missing path on line 40 still uses `json_escape`. Either keep both
  paths consistent (use `jq` only) by also gating the early-exit on jq's
  presence (already done — that path can simply emit a hardcoded fallback
  JSON string), or remove the function and inline a fallback.
- Replace `grep -q "refs/heads/$branch"` with `grep -qF "refs/heads/$branch"`
  so a branch name containing regex meta-chars (rare but possible:
  `feat-foo.bar`) doesn't false-match.
- The `git branch -vv` parser `[[ $line == \** ]] && continue` skips lines
  starting with `*`, but git also prefixes the active branch with `+`
  in worktrees. Add `[[ $line == +* ]] && continue` (use a single
  `[[ $line =~ ^[*+] ]] && continue`).
- Insert Task 0's session-id capture logic at the very top of the script,
  BEFORE the existing logic, so even early failures still register the
  session.

### Task 12: Fix status_line.sh stale PR cache

**What:**

- Add an mtime check before trusting the cached PR JSON:
  ```bash
  pr_cache_file="/tmp/ci_watch_pr_${slot}"
  if [ -f "$pr_cache_file" ]; then
      now=$(date +%s)
      mtime=$(stat -f %m "$pr_cache_file" 2>/dev/null || stat -c %Y "$pr_cache_file" 2>/dev/null || echo 0)
      if [ $((now - mtime)) -gt 600 ]; then
          # Stale — pretend it doesn't exist.
          pr_cache_file=""
      fi
  fi
  ```
- Apply the same age check (with a shorter threshold, say 60s) to
  `/tmp/ci_watch_state_${slot}` — a state file older than the watcher's
  5-min health-retry window is definitely orphaned.

### Task 13: Background afplay in notify_waiting.sh

**What:**

- Change
  ```bash
  afplay /System/Library/Sounds/Glass.aiff
  ```
  to
  ```bash
  if command -v afplay >/dev/null 2>&1; then
      afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
      disown
  fi
  ```
  so a slow audio system doesn't block the Stop hook (which Claude Code
  waits on synchronously).
- Apply the same pattern in any other script that calls `afplay`
  directly — `grep -rn afplay ~/.claude/scripts/` to verify.

---

## Dependency graph

- **Task 0** is the prerequisite for Tasks 1, 2, and the `/ci` skill change.
- **Tasks 1, 3–13** can be done in parallel after Task 0.
- **Task 2** depends on Task 0 *and* Task 1 (needs `BRANCH_KEY`).

## Out of scope (explicitly)

- Cleanup of orphaned `/tmp/ci_watch_*` files from killed sessions
  (documented gap; separate sweeper).
- A central registry of live sessions + webhook ports.
- Restructuring `session_start.sh` to not race when two windows share a
  base repo.
