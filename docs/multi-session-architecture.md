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
(CI watcher state files, status-line readouts) stay correctly
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
                          - reads $CLAUDE_CODE_SESSION_ID and cwd
                          - calls Monitor({command, persistent: true}) with both
                            inlined as literals in the command string
                          - writes the returned task id to
                            /tmp/ci_watch_task_<slot>
5. watcher runs       → slot = $CLAUDE_CODE_SESSION_ID  (full UUID)
                      → writes /tmp/ci_watch_state_<slot> as
                          "<branch>:<state>" every poll
                      → prints notifications to stdout; Monitor relays each
                        line to the session
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
`/ci-watcher` skill inlines that value into the `Monitor` command it launches,
so all four consumers (the launcher, the watcher, the status line, and any
future hook script) see the same value with no inter-process bookkeeping.

### How each consumer gets the slot

| Component           | How it gets the slot                                                                                      |
| ------------------- | --------------------------------------------------------------------------------------------------------- |
| `/ci-watcher` skill | Reads `$CLAUDE_CODE_SESSION_ID` (env var injected into the Bash-tool subshell).                           |
| `ci_watch.py`       | Reads `$CLAUDE_CODE_SESSION_ID` (set explicitly by the Monitor command). Fails loud and exits 2 if unset. |
| `status_line.sh`    | Parses `.session_id` from the hook payload (env vars are not available in the status-line context).       |
| `session_start.sh`  | Does not need it — the SessionStart hook no longer writes any session-identity files.                     |

`status_line.sh` runs as a hook, not as a user-tool subshell, so the
`CLAUDE_CODE_SESSION_ID` env var isn't injected. It receives `session_id` as a
top-level field of the JSON payload Claude Code passes on stdin, and slices it
out with the same `jq` call that pulls `current_dir` and the rate-limit
fields.

The watcher does NOT inherit the env var. `Monitor` runs in the same shell
environment as the Bash tool, but neither its cwd nor its env inheritance is
contractually guaranteed, so the `/ci-watcher` skill resolves
`$CLAUDE_CODE_SESSION_ID` and the repo dir in a preceding Bash call and inlines
both into the `Monitor` command string as literals:
`cd '<DIR>' && exec env CLAUDE_CODE_SESSION_ID='<UUID>' uv run … ci_watch.py '<BRANCH>'`.
`exec` makes the process `Monitor` tracks the watcher itself, so `TaskStop`
kills the real process instead of an orphanable parent shell.

The literals are **single**-quoted, not double-quoted. A shell runs this string,
and a git branch name may legally contain `$`, backticks, `;` and `&`. Double
quotes stop word splitting and `;`/`&` but NOT `$VAR`, `` `cmd` `` or `$(cmd)`,
so a branch named `x$(id)` would execute. Only single quotes suppress every
substitution; a literal single quote inside a value is written `'\''`.

---

## State File Naming

All CI watcher state lives in `/tmp/` and is keyed on the full session UUID:

```
/tmp/ci_watch_state_<slot>      writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_lock_<slot>       writer/reader: ci_watch.py (PID lockfile)
/tmp/ci_watch_pr_<slot>         writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_<slot>.log        writer: redirected STDERR only    readers: humans (tail -f)
                                (stdout is the Monitor event stream, not the log)
/tmp/ci_watch_task_<slot>       writer: /ci-watcher skill
                                readers: /ci-watcher stop, relaunch (Monitor task id)
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

1. `/ci-watcher` skill runs inside Claude. It reads `$CLAUDE_CODE_SESSION_ID`
   and the repo dir. If the session id is unset, the skill fails loud and exits.
2. Calls `Monitor({command, persistent: true})` with the session id, repo dir,
   and branch inlined into the command as single-quoted literals, and stderr
   appended to `/tmp/ci_watch_<slot>.log`. The skill then writes the returned
   task id to `/tmp/ci_watch_task_<slot>` atomically (temp file + `mv`), and
   only afterwards polls the lockfile (1s, max 10 tries) to confirm the watcher
   actually came up. Persisting before verifying is deliberate: a watcher that
   is alive but slow to appear must still be stoppable. On a `DEAD` verdict the
   skill shows the tail of the log, since a dead-on-arrival watcher writes its
   error to stderr and stderr no longer reaches `TaskOutput`.
3. Watcher reads `$CLAUDE_CODE_SESSION_ID` → `slot`. If unset, exits 2 to
   stderr immediately.
4. Watcher takes the lock at `/tmp/ci_watch_lock_<slot>`. If a stale
   predecessor with the same slot exists (i.e. the same session re-ran
   `/ci-watcher`), it's SIGTERM'd and the new watcher claims the lock.
5. Watcher writes `<branch>:running` to the state file, registers an `atexit`
   cleanup that unlinks state/pr/lock, and enters its main loop.

Two sessions on the same branch each have a different slot, so their
locks/state/pr files are disjoint. They never kill each other.

### Lifetime

The watcher runs until one of three things happens:

1. `TaskStop` on the stored Monitor task id — either from `/ci-watcher stop` or
   from a branch-switch relaunch.
2. The process exits on its own terminal condition (PR closed without merge, no
   CI on the default branch, main-CI timeout, main CI resolved).
3. The session ends and Monitor tears the `persistent: true` task down.

Case 3 is what makes the old per-loop webhook health check unnecessary: the
harness now owns the "do not outlive the session" guarantee.

`/ci-watcher stop` does not depend on the task-id file alone. If
`/tmp/ci_watch_task_<slot>` is missing (reaped from `/tmp`, or the session died
between `Monitor` returning and the id being persisted) but the lockfile shows a
live watcher, the skill kills that PID directly. The old kill-flag mechanism
needed only the session id, so stop always worked; this keeps that property.

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

- **Graceful exit** (SIGTERM or SIGINT, including the `TaskStop` path): the
  `atexit` closure unlinks state/pr/lock. A session-end SIGKILL can skip
  `atexit` and leave orphan files — the same case the `⚠ ci watcher died`
  rendering already covers.
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
different Monitor tasks.
```

---

## Known Limitations / Gaps

- **Orphaned `/tmp` files on SIGKILL/power-off.** The `atexit` closure cleans
  up on normal shutdown. SIGKILL or panicked watchers leave files behind.
  `status_line.sh` detects watcher-death via PID + arg-grep and renders
  `⚠ ci watcher died` instead of stale state, but nothing actively
  garbage-collects the files. They rot in `/tmp` until reboot. Because slots
  are per-session, orphans never collide with new watchers.

- **stdout must stay notification-only.** `Monitor` turns every stdout line
  into a session notification and automatically stops a monitor that produces
  too many events. A single diagnostic on stdout per loop iteration would be
  one notification per second and the harness would kill the watcher. That is
  why every diagnostic in `ci_watch.py` writes to stderr, and only `notify()`
  writes to stdout.

- **`session_start.sh` runs `git fetch -p` and `git merge --ff-only` on every
  start.** Two simultaneous sessions in the same base dir will race here;
  git's ref-locking handles it but worst case one sees "Already up to date."

---

## Quick reference

| Question                                           | Answer                                                                                                                                |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Where does the slot come from?                     | The full `CLAUDE_CODE_SESSION_ID` env var (a UUID minted by the Claude Code harness per session).                                     |
| How does `/ci-watcher` get it?                     | Reads `$CLAUDE_CODE_SESSION_ID` from the Bash-tool subshell environment.                                                              |
| How does the watcher get it?                       | Reads `$CLAUDE_CODE_SESSION_ID`, set explicitly by the `Monitor` command via `env`. Exits 2 if unset.                                 |
| How does `status_line.sh` get it?                  | Parses `.session_id` from its hook payload — env vars are unavailable in the status-line context.                                     |
| What's the state-file key?                         | `slot = $CLAUDE_CODE_SESSION_ID` (full UUID).                                                                                         |
| What's the state-file content?                     | A single line `<branch>:<state>` (e.g. `feat/auth:passed`).                                                                           |
| What stops two watchers from colliding?            | PID-file lock at `/tmp/ci_watch_lock_<slot>`. Disjoint paths across sessions; in-session re-launch evicts the predecessor by SIGTERM. |
| What stops the watcher from outliving the session? | Monitor's `persistent: true` task ends when the session ends; `TaskStop` ends it early.                                               |
