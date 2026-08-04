# Multi-Session Architecture

How `~/.claude/` handles multiple Claude Code sessions running simultaneously
across multiple terminal windows, multiple repos, and multiple feature worktrees.

This is an internal design doc. It describes what the code actually does today,
keyed off `session_start.sh`, `status_line.sh`, the `/ci-watcher` skill, and
`ci_watch.py`.

---

## Overview

The user runs many Claude Code windows at once: a window on `main` in repo-A,
a window on `feat/auth` in a worktree of repo-B, a second window on `main` in
repo-B, and so on. Each is an independent Claude process with its own
`session_id`. The architecture's job is to make per-session state
(CI watcher state files, status-line readouts, webhook routing) stay correctly
isolated as the user `cd`s between dirs and as multiple windows touch the same
branch from different sessions.

The fix that makes this work: every CI-related `/tmp` file is keyed on the
**full** `session_id` UUID (the value Claude Code injects as the
`CLAUDE_CODE_SESSION_ID` environment variable into Bash-tool subshells, and
that the harness includes as `.session_id` in every status-line and hook
payload). Two sessions on the same branch never collide because they have
different session_ids.

---

## Typical Session Lifecycle

```
1. open terminal in   ~/repo-b/                       (base repo, branch=main)
2. claude starts      → SessionStart hook fires
                      → session_start.sh runs env validation, fetch, worktree
                        cleanup. No session-identity bookkeeping.
3. user runs /new-feature
                      → claude creates ~/repo-b/.claude/worktrees/feat-auth/
                        with branch feat-auth checked out
                      → claude `cd`s into the worktree (mid-session)
                      → no new session_start fires; CLAUDE_CODE_SESSION_ID
                        is unchanged across `cd`.
4. user runs /ci-watcher → /ci-watcher skill (running inside the same Claude process):
                          - calls mcp__webhook__get_port → "PORT:TOKEN"
                          - reads $CLAUDE_CODE_SESSION_ID from the env
                          - launches ci_watch.py detached with
                            (BRANCH, PORT, SESSION_TOKEN) as argv
                          - the env var is inherited by the detached child
5. watcher runs       → slot = $CLAUDE_CODE_SESSION_ID  (full UUID)
                      → writes /tmp/ci_watch_state_<slot> as
                          "<branch>:<state>" every poll
                      → posts results to http://127.0.0.1:$PORT
6. status_line ticks  → status_line.sh hook receives payload with session_id
                      → slot = .session_id from the payload
                      → reads /tmp/ci_watch_state_<slot>      ← agrees
                              /tmp/ci_watch_pr_<slot>         ← agrees
```

ASCII view of two windows running at the same time:

```
┌─ Window A ──────────────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-a              session_id: aaaaaaaa-aaaa-aaaa-aaaa-…                    │
│ branch: main                                                                        │
│ /ci-watcher not running on main → no /tmp/ci_watch_*                                │
└─────────────────────────────────────────────────────────────────────────────────────┘

┌─ Window B ──────────────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-b/.claude/worktrees/feat-auth   session_id: bbbbbbbb-bbbb-bbbb-bbbb-…   │
│ branch: feat/auth                                                                   │
│ /tmp/ci_watch_state_bbbbbbbb-bbbb-bbbb-bbbb-…  contents: "feat/auth:running"        │
│ /tmp/ci_watch_pr_bbbbbbbb-bbbb-bbbb-bbbb-…     ← watcher writes JSON                │
│ status_line reads same files                   ← agrees                             │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Session Identity

`slot = $CLAUDE_CODE_SESSION_ID` — the full session UUID (36 chars including
dashes) that Claude Code's harness injects into every Bash-tool subshell. The
detached watcher inherits the env var from the launching shell, so all four
consumers (the launcher, the watcher, the status line, and any future hook
script) see the same value with no inter-process bookkeeping.

### How each consumer gets the slot

| Component           | How it gets the slot                                                                                      |
| ------------------- | --------------------------------------------------------------------------------------------------------- |
| `/ci-watcher` skill | Reads `$CLAUDE_CODE_SESSION_ID` (env var injected into the Bash-tool subshell).                           |
| `ci_watch.py`       | Reads `$CLAUDE_CODE_SESSION_ID` (inherited from the launching subshell). Fails loud and exits 2 if unset. |
| `status_line.sh`    | Parses `.session_id` from the hook payload (env vars are not available in the status-line context).       |
| `session_start.sh`  | Does not need it — the SessionStart hook no longer writes any session-identity files.                     |

`status_line.sh` runs as a hook, not as a user-tool subshell, so the
`CLAUDE_CODE_SESSION_ID` env var isn't injected. It receives `session_id` as a
top-level field of the JSON payload Claude Code passes on stdin, and slices it
out with the same `jq` call that pulls `current_dir` and the rate-limit
fields.

The detached watcher inherits the env var because the `/ci-watcher` skill launches it
from a Bash-tool subshell (with shell-level backgrounding `&`, not via the
`run_in_background` parameter). Children of that subshell inherit its
environment, including `CLAUDE_CODE_SESSION_ID`.

---

## State File Naming

All CI watcher state lives in `/tmp/` and is keyed on the full session UUID:

```
/tmp/ci_watch_state_<slot>      writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_lock_<slot>       writer/reader: ci_watch.py (PID lockfile)
/tmp/ci_watch_pr_<slot>         writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_<slot>.log        writer: redirected stdout/stderr  readers: humans (tail -f)
```

`<slot>` is the full UUID, e.g. `a3b4c5d6-e7f8-49a0-b1c2-d3e4f5a6b7c8`.
Filename length is well within `PATH_MAX`.

The state file is a **single line** with the format `<branch>:<state>`, e.g.
`feat/auth:running` or `feat__lint:passed`. `status_line.sh` parses it with
`cut -d:` (split on the first colon) so the watcher's branch is available for
display when the user `cd`s to a different branch.

State values: `running`, `passed`, `failed`, `conflict`, `behind`, `no-runs`,
`merging`, `merged-passed`, `merged-failed`, `timeout`. `status_line.sh`
color-codes them. The PR cache file is JSON containing url, number, state,
mergeable, mergeStateStatus, mergeCommit so the status line never calls `gh`
itself.

Atomic writes: every file is written via `tempfile.mkstemp + os.replace` so a
slow reader never observes partial content.

---

## CI Watcher Lifecycle

### Startup (from `/ci-watcher`)

1. `/ci-watcher` skill runs inside Claude. It calls `mcp__webhook__get_port`, gets
   `PORT:TOKEN`, and reads `$CLAUDE_CODE_SESSION_ID` from the env. If the var
   is unset, the skill fails loud and exits.
2. Launches `uv run ~/.claude/scripts/ci_watch.py "$BRANCH" "$PORT" "$SESSION_TOKEN"`
   with shell-level backgrounding (`</dev/null >>log 2>&1 &`) — NOT via the
   Bash tool's `run_in_background=true`, which would kill the process when
   the subagent exits.
3. Watcher reads `$CLAUDE_CODE_SESSION_ID` → `slot`. If unset, exits 2 to
   stderr immediately.
4. Watcher takes the lock at `/tmp/ci_watch_lock_<slot>`. If a stale
   predecessor with the same slot exists (i.e. the same session re-ran
   `/ci-watcher`), it's SIGTERM'd and the new watcher claims the lock.
5. Watcher writes `<branch>:running` to the state file, registers an `atexit`
   cleanup that unlinks state/pr/lock, and enters its main loop.

Two sessions on the same branch each have a different slot, so their
locks/state/pr files are disjoint. They never kill each other.

### Health check

Every loop iteration:
```
GET http://127.0.0.1:$PORT/health   → expects "ok:$SESSION_TOKEN"
```

5 attempts × 2s sleep window for macOS sleep/wake recovery. If all 5 fail,
the watcher exits cleanly via the `atexit` cleanup. The token check guards
against OS port reuse: if the original session died and another session got
assigned the same port, the token will mismatch and the watcher exits instead
of spamming a stranger.

### Status line consumption

`status_line.sh` runs once per status refresh. It:
1. Parses cwd, git_dir, context %, rate-limit fields, and `session_id` from
   the hook payload.
2. Sets `slot = $session_id`. If empty, the CI segment is silently skipped.
3. Reads `/tmp/ci_watch_state_<slot>`, splits on `:` to get
   `(stored_branch, state)`, and reads `/tmp/ci_watch_pr_<slot>` for PR
   metadata.
4. Renders the third status line: `PR #N | ci: <state> | HH:MM:SS`. When
   `stored_branch` differs from the cwd's git branch, the watcher's branch is
   appended in parens — e.g. `ci: passed (feat/auth)` — so the user can tell
   whether the displayed CI status applies to their current cwd.

### Self-cleanup

- **Graceful exit** (SIGTERM, SIGINT, or webhook MCP died → 5 health-check
  retries fail): the `atexit` closure unlinks state/pr/lock.
- **SIGKILL or power-off**: orphan files remain. `status_line.sh` detects this
  via a `kill -0` + `ps` arg-grep on the lock-file's PID and renders
  `⚠ ci watcher died` instead of a stale state. Orphan files are otherwise
  harmless because every new session has a different slot.

---

## Multi-Window Topology

### Two windows, same repo, different branches

```
Window 1: cwd=~/r/.claude/worktrees/feat-a   session_id=11111111-…   slot=11111111-…
Window 2: cwd=~/r/.claude/worktrees/feat-b   session_id=22222222-…   slot=22222222-…

Watcher 1: /tmp/ci_watch_state_11111111-…   contents: "feat-a:running"
Watcher 2: /tmp/ci_watch_state_22222222-…   contents: "feat-b:running"
                                  ↑ disjoint, no contention
```

### Two windows, same repo, SAME branch (the previously-broken case)

```
Window 1: cwd=~/r/.claude/worktrees/feat-a   session_id=11111111-…   slot=11111111-…
Window 2: cwd=~/r/.claude/worktrees/feat-a   session_id=22222222-…   slot=22222222-…

Watcher 1: /tmp/ci_watch_state_11111111-…   contents: "feat-a:running"
Watcher 2: /tmp/ci_watch_state_22222222-…   contents: "feat-a:running"
                                  ↑ still disjoint thanks to session_id keying
```

Each window's `status_line.sh` extracts its own `session_id` from its own
payload, builds its own slot, and reads its own watcher's state. Each
window's `/ci-watcher` reads its own `$CLAUDE_CODE_SESSION_ID` — different Claude
processes have different session_ids.

### Two windows, different repos

```
Window 1: cwd=~/repo-a                        session_id=aaaaaaaa-…
Window 2: cwd=~/repo-b/.claude/worktrees/x    session_id=bbbbbbbb-…

Completely isolated — different session_ids, different slots,
different webhook MCP servers (different ports + session tokens).
```

---

## Known Limitations / Gaps

- **Orphaned `/tmp` files on SIGKILL/power-off.** The `atexit` closure cleans
  up on normal shutdown. SIGKILL or panicked watchers leave files behind.
  `status_line.sh` detects watcher-death via PID + arg-grep and renders
  `⚠ ci watcher died` instead of stale state, but nothing actively
  garbage-collects the files. They rot in `/tmp` until reboot. Because slots
  are per-session, orphans never collide with new watchers.

- **No cross-session broadcast of webhook ports.** Each session's webhook MCP
  binds an OS-assigned port and mints its own token. Reaching another
  session's webhook from outside that session is not supported. The only
  consumer that holds the port is the watcher launched by that same session.

- **`session_start.sh` runs `git fetch -p` and `git merge --ff-only` on every
  start.** Two simultaneous sessions in the same base dir will race here;
  git's ref-locking handles it but worst case one sees "Already up to date."

---

## Quick reference

| Question                                           | Answer                                                                                                                                |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Where does the slot come from?                     | The full `CLAUDE_CODE_SESSION_ID` env var (a UUID minted by the Claude Code harness per session).                                     |
| How does `/ci-watcher` get it?                     | Reads `$CLAUDE_CODE_SESSION_ID` from the Bash-tool subshell environment.                                                              |
| How does the watcher get it?                       | Reads `$CLAUDE_CODE_SESSION_ID` (inherited from the launching subshell). Exits 2 if unset.                                            |
| How does `status_line.sh` get it?                  | Parses `.session_id` from its hook payload — env vars are unavailable in the status-line context.                                     |
| What's the state-file key?                         | `slot = $CLAUDE_CODE_SESSION_ID` (full UUID).                                                                                         |
| What's the state-file content?                     | A single line `<branch>:<state>` (e.g. `feat/auth:passed`).                                                                           |
| What stops two watchers from colliding?            | PID-file lock at `/tmp/ci_watch_lock_<slot>`. Disjoint paths across sessions; in-session re-launch evicts the predecessor by SIGTERM. |
| What stops the watcher from outliving the session? | Per-loop `/health` check against the session's webhook MCP, validated by `SESSION_TOKEN`.                                             |
