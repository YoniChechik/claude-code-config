# Multi-Session Architecture

How `~/.claude/` handles multiple Claude Code sessions running simultaneously
across multiple terminal windows, multiple repos, and multiple feature clones.

This is an internal design doc. It describes what the code actually does today,
keyed off `session_start.sh`, `status_line.sh`, `lib/session_id.sh`, the `/ci`
skill, and `ci_watch_persistent.sh`.

---

## Overview

The user runs many Claude Code windows at once: a window on `main` in repo-A,
a window on `feat/auth` in a clone of repo-B, a second window on `main` in
repo-B, and so on. Each is an independent Claude process with its own
`session_id`. The architecture's job is to make per-session state
(CI watcher state files, status-line readouts, webhook routing) stay correctly
isolated as the user `cd`s between dirs and as multiple windows touch the same
branch from different sessions.

The fix that makes this work: every CI-related `/tmp` file is keyed by
`<branch_key>_<sid8>` so two sessions on the same branch never collide, and
every component derives the same `sid8` for the live session via a `cd`-immune
identity path anchored on the Claude Code process PID.

---

## Typical Session Lifecycle

```
1. open terminal in   ~/repo-b/                       (base repo, branch=main)
2. claude starts      → SessionStart hook fires
                      → session_start.sh extracts session_id from payload,
                        computes SID8 = first 8 chars
                      → writes:
                          ~/.claude/cache/ppid-session/<PPID>            = SID8
                          ~/.claude/session-env/<session_id>/sid8        = SID8
3. user runs /new-feature
                      → claude creates ~/repo-b/_clones/feat-auth/
                        with branch feat-auth checked out
                      → claude `cd`s into the clone (mid-session)
                      → no new session_start fires; SID8 still resolvable
                        because PPID hasn't changed.
4. user runs /ci      → /ci skill (running inside the same Claude process):
                          - calls mcp__webhook__get_port → "PORT:TOKEN"
                          - reads ~/.claude/cache/ppid-session/$PPID → SID8
                          - launches ci_watch_persistent.sh detached with
                            (PORT, BRANCH, SESSION_TOKEN, SID8) as argv
5. watcher runs       → SLOT = "${BRANCH//\//__}_${SID8}"
                      → writes /tmp/ci_watch_state_<SLOT> every poll
                      → posts results to http://127.0.0.1:$PORT
6. status_line ticks  → status_line.sh hook receives payload with session_id
                      → SID8 = ${session_id:0:8}  (no cache lookup needed)
                      → reads /tmp/ci_watch_state_<SLOT>      ← agrees
                              /tmp/ci_watch_pr_<SLOT>         ← agrees
```

ASCII view of two windows running at the same time:

```
┌─ Window A ────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-a              session_id: aaaaaaaa-…    SID8: aaaaaaaa       │
│ branch: main                                                              │
│ ppid-session/<PIDa>                        → aaaaaaaa                     │
│ /ci not running on main → no /tmp/ci_watch_*                              │
└───────────────────────────────────────────────────────────────────────────┘

┌─ Window B ────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-b/_clones/feat-auth   session_id: bbbbbbbb-…  SID8: bbbbbbbb  │
│ branch: feat/auth          BRANCH_KEY: feat__auth   SLOT: feat__auth_bbbb…│
│ ppid-session/<PIDb>                                  → bbbbbbbb           │
│ /tmp/ci_watch_state_feat__auth_bbbbbbbb     ← watcher writes              │
│ /tmp/ci_watch_pr_feat__auth_bbbbbbbb        ← watcher writes              │
│ status_line reads same files                ← agrees                      │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Session Identity

`SID8` = the first 8 characters of the harness-generated `session_id` UUID.
That short form is what every consumer keys on. The full UUID is preserved in
`~/.claude/session-env/<session_id>/sid8` for debugging.

### How each consumer gets SID8

| Component                   | How it gets SID8                                                                     | Notes                                                                                           |
|-----------------------------|--------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `session_start.sh`          | Extracts `session_id` from the SessionStart hook payload (stdin JSON)                | Writes the canonical mappings: `cache/ppid-session/<PPID>` and `session-env/<session_id>/sid8`. |
| `status_line.sh`            | Extracts `session_id` directly from its hook payload (`.session_id`)                 | The status_line payload already contains `session_id` at the top level. No cache lookup needed. |
| `/ci` skill                 | Reads `cache/ppid-session/$PPID`, then passes SID8 to the watcher                    | `$PPID` inside the skill bash block = the Claude Code process. Stable across `cd`.              |
| `ci_watch_persistent.sh`    | Receives SID8 as argv 4 from `/ci`                                                   | Detached background process — no stdin, no hook payload to read.                                |
| `lib/session_id.sh` helpers | `sid8_from_payload()` (parses JSON), `sid8_from_ppid()` (reads `ppid-session/$PPID`) | Available for any future hook script that needs SID8.                                           |

### Why PPID is the right anchor

The Claude Code process PID is stable for the entire lifetime of a session:
`/new-feature` cds into a clone, `/cd-permanent` cds elsewhere, the user
manually cds — none of those change PID. The session_id is also stable, but
it's only handed to scripts via hook payloads; processes spawned later (the
`/ci` watcher's launcher block, future hooks that don't get a payload) need
some other anchor.

`$PPID` inside a hook script equals the Claude Code process that spawned the
hook, because hooks run as `bash $HOME/.claude/scripts/foo.sh` directly under
Claude with no intermediate shell. So writing
`cache/ppid-session/$PPID` from `session_start.sh` and reading it from any
later script under the same Claude process resolves to the same SID8.

This replaces an earlier `cwd-session/<sha1(cwd)[:12]>` design that broke the
moment Claude `cd`'d mid-session: the hash key in the new dir didn't exist
because `session_start.sh` only ran for the original cwd. PPID-keyed lookup is
immune to all `cd` operations.

`status_line.sh` doesn't need any cache: its hook payload already contains
`session_id` at the top level, so it just slices the first 8 chars directly.

---

## State File Naming

All CI watcher state lives in `/tmp/` and is keyed by `SLOT = ${BRANCH_KEY}_${SID8}`,
where `BRANCH_KEY = ${BRANCH//\//__}` (slashes replaced with `__` so branches like
`feature/foo` don't try to create non-existent parent dirs).

```
/tmp/ci_watch_state_<SLOT>      writer: ci_watch_persistent.sh   reader: status_line.sh
/tmp/ci_watch_lock_<SLOT>       writer/reader: ci_watch_persistent.sh (PID lockfile)
/tmp/ci_watch_pr_<SLOT>         writer: ci_watch_persistent.sh   reader: status_line.sh
/tmp/ci_watch_<SLOT>.log        writer: redirected stdout/stderr  readers: humans (tail -f)
```

Examples:

```
branch=main, sid8=a3b4c5d6
  → SLOT = main_a3b4c5d6
  → /tmp/ci_watch_state_main_a3b4c5d6
  → /tmp/ci_watch_pr_main_a3b4c5d6

branch=feat/auth, sid8=9f8e7d6c
  → BRANCH_KEY = feat__auth
  → SLOT = feat__auth_9f8e7d6c
  → /tmp/ci_watch_state_feat__auth_9f8e7d6c
  → /tmp/ci_watch_pr_feat__auth_9f8e7d6c
```

State values written to `ci_watch_state_<SLOT>`: `running`, `passed`, `failed`,
`conflict`, `behind`, `merging`. `status_line.sh` color-codes them. The PR
cache file is JSON containing url, number, state, mergeable, mergeStateStatus,
mergeCommit so the status line never calls `gh` itself.

Atomic writes: every file is written via `mktemp + mv -f` so a slow reader
never observes partial content.

---

## CI Watcher Lifecycle

### Startup (from `/ci`)

1. `/ci` skill runs inside Claude. It calls `mcp__webhook__get_port`, gets
   `PORT:TOKEN`, reads `cache/ppid-session/$PPID` → SID8 (falling back to the
   literal string `unknown` on miss).
2. Launches `ci_watch_persistent.sh "$PORT" "$BRANCH" "$SESSION_TOKEN" "$SID8"`
   with shell-level backgrounding (`</dev/null >>log 2>&1 &`) — NOT via the
   Bash tool's `run_in_background=true`, which would kill the process when
   the subagent exits.
3. Watcher computes `BRANCH_KEY` and `SLOT`, sets up an EXIT trap that cleans
   `/tmp/ci_watch_state_<SLOT>` and `/tmp/ci_watch_pr_<SLOT>` (unless
   `KEEP_STATE_FILE=1`) and the lock file.
4. Watcher writes its PID into `/tmp/ci_watch_lock_<SLOT>`. If a stale
   predecessor exists (same SLOT, alive, command line matches), it's killed
   and the new watcher claims the lock — that's how a re-launched `/ci` from
   the same window cleanly takes over.
5. Watcher writes `running` to the state file and enters its main loop.

Because the lock is keyed on `SLOT` (which includes SID8), two windows on the
same branch each get their own watcher and their own lock. They do NOT kill
each other.

### Health check

Every loop iteration:
```
GET http://127.0.0.1:$PORT/health   → expects "ok:$SESSION_TOKEN"
```

5 attempts × 2s sleep window for macOS sleep/wake recovery. If all 5 fail,
the watcher exits cleanly. The token check guards against OS port reuse: if
the original session died and another session got assigned the same port,
the token will mismatch and the watcher exits instead of spamming a stranger.

### Status line consumption

`status_line.sh` runs once per status refresh. It:
1. Parses cwd, git_dir, context %, rate-limit %, and `session_id` from the
   hook payload.
2. Sets `SID8 = ${session_id:0:8}`.
3. Builds SLOT, reads `/tmp/ci_watch_state_<SLOT>` (max age 120s) and
   `/tmp/ci_watch_pr_<SLOT>` (max age 600s).
4. Renders the third status line: `PR #N | ci: <state> | HH:MM:SS`.

Stale-file age gates protect against orphaned watchers (SIGKILL, machine
power-off) that didn't run their EXIT trap.

---

## Multi-Window Topology

### Two windows, same repo, different branches

```
Window 1: cwd=~/r/_clones/feat-a   SID8=11111111   SLOT=feat-a_11111111
Window 2: cwd=~/r/_clones/feat-b   SID8=22222222   SLOT=feat-b_22222222

Watcher 1: /tmp/ci_watch_state_feat-a_11111111
Watcher 2: /tmp/ci_watch_state_feat-b_22222222
                                  ↑ disjoint, no contention
```

### Two windows, same repo, SAME branch (the previously-broken case)

```
Window 1: cwd=~/r/_clones/feat-a   SID8=11111111   SLOT=feat-a_11111111
Window 2: cwd=~/r/_clones/feat-a   SID8=22222222   SLOT=feat-a_22222222
                                                   (yes — Window 2 is a
                                                    second Claude session in
                                                    the same dir)

Watcher 1: /tmp/ci_watch_state_feat-a_11111111
Watcher 2: /tmp/ci_watch_state_feat-a_22222222
                                  ↑ still disjoint thanks to SID8
```

Each window's `status_line.sh` extracts its own `session_id` from its own
payload, builds its own SLOT, and reads its own watcher's state. Each window's
`/ci` reads its own `ppid-session/<PID>` entry — different Claude PIDs map to
different SID8s.

### Two windows, different repos

```
Window 1: cwd=~/repo-a              SID8=aaaaaaaa
Window 2: cwd=~/repo-b/_clones/x    SID8=bbbbbbbb

Completely isolated — different PPIDs, different SID8s, different SLOTs,
different webhook MCP servers (different ports + session tokens).
```

---

## Known Limitations / Gaps

- **Orphaned `/tmp` files.** EXIT traps clean up on normal shutdown. SIGKILL,
  power-off, or a panicked watcher leave files behind. `status_line.sh` has
  age gates (120s for state, 600s for PR cache) to ignore obvious orphans,
  but nothing actively garbage-collects.

- **Orphaned `ppid-session/<PID>` files.** When a Claude session ends, nothing
  removes its `cache/ppid-session/<PID>` entry. If the OS later recycles that
  PID for a new Claude process before the new session_start fires, there's a
  brief window where lookups would return the *old* SID8. In practice
  `session_start.sh` runs immediately at startup and does atomic `mv -f`, so
  the stale value is overwritten before any consumer can observe it. A
  periodic GC (or removing the file in a session_end hook) would be a clean
  follow-up.

- **No cross-session broadcast of webhook ports.** Each session's webhook MCP
  binds an OS-assigned port and mints its own token. Reaching another
  session's webhook from outside that session is not supported. The only
  consumer that holds the port is the watcher launched by that same session.

- **`session_start.sh` runs `git fetch -p` and `git merge --ff-only` on every
  start.** Two simultaneous sessions in the same base dir will race here;
  git's ref-locking handles it but worst case one sees "Already up to date."

---

## Flow Validation: /new-feature → /ci scenario

Walking through a representative session to confirm SID8 stays consistent
across cwd changes:

```
T0  user opens terminal in ~/repo-b/   (base repo, branch=main)
T1  claude starts                     PID=11000   session_id=a3b4c5d6-e7f8-…
                                       SID8=a3b4c5d6
    SessionStart hook fires:
      cache/ppid-session/11000                 = a3b4c5d6
      session-env/a3b4c5d6-…/sid8              = a3b4c5d6

T2  status_line.sh tick (still in ~/repo-b):
      payload.session_id = a3b4c5d6-…
      SID8 = a3b4c5d6                                 ✓ same SID8

T3  user runs /new-feature feat/auth:
      claude creates ~/repo-b/_clones/feat-auth/ on branch feat/auth
      claude `cd`s into it (still PID 11000, still session_id a3b4c5d6-…)

T4  status_line.sh tick (now in clone):
      payload.session_id = a3b4c5d6-…  (unchanged)
      SID8 = a3b4c5d6                                 ✓ same SID8

T5  user runs /ci (cwd = clone):
      $PPID inside skill bash = 11000
      cache/ppid-session/11000 → a3b4c5d6             ✓ same SID8
      launches watcher with SID8=a3b4c5d6, BRANCH=feat/auth
      SLOT = feat__auth_a3b4c5d6
      /tmp/ci_watch_state_feat__auth_a3b4c5d6        ← watcher writes

T6  status_line.sh tick (clone):
      SID8 = a3b4c5d6 (from payload)
      SLOT = feat__auth_a3b4c5d6                     ✓ matches watcher
      reads /tmp/ci_watch_state_feat__auth_a3b4c5d6  ✓ shows correct state

T7  second window on the same branch:
      different Claude PID (e.g. 22000), different session_id
      cache/ppid-session/22000 → SID8=b9c8d7e6
      independent SLOT = feat__auth_b9c8d7e6         ✓ no collision
```

The PPID-keyed identity path keeps SID8 consistent across `/new-feature`'s
mid-session `cd` (T3 → T5), and the session_id-in-payload path keeps
`status_line.sh` self-sufficient with no cache lookup at all.

---

## Quick reference

| Question                                           | Answer                                                                                              |
|----------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| Where does SID8 come from?                         | First 8 chars of harness `session_id`, extracted by `session_start.sh`.                             |
| Where is it cached?                                | `cache/ppid-session/<PPID>` and `session-env/<session_id>/sid8`.                                    |
| How does `status_line.sh` get it?                  | Slices `${session_id:0:8}` from its hook payload — no cache lookup.                                 |
| How does `/ci` get it?                             | Reads `cache/ppid-session/$PPID`, passes SID8 as argv 4 to the watcher.                             |
| How does the watcher get it?                       | Argv 4 from `/ci`.                                                                                  |
| What's the state-file key?                         | `SLOT = ${BRANCH//\//__}_${SID8}`.                                                                  |
| What stops two watchers from colliding?            | Lock file `/tmp/ci_watch_lock_<SLOT>` — keyed on SLOT, so different sessions don't kill each other. |
| What stops the watcher from outliving the session? | Per-loop `/health` check against the session's webhook MCP, validated by `SESSION_TOKEN`.           |
