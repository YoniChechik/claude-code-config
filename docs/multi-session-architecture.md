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
`session_id`. On top of that, ONE session can watch SEVERAL branches at the same
time — a session that launched three PR workflows runs three `ci_watch.py`
processes. The architecture's job is to keep all of that state (CI watcher state
files, status-line readouts) correctly isolated as the user `cd`s between dirs,
as one session watches several branches, and as multiple windows touch the same
branch from different sessions.

The mechanism that makes this work: every per-watcher `/tmp` file is keyed on a
`SLOT` built from three things — the **full** `session_id` UUID (the value
Claude Code injects as the `CLAUDE_CODE_SESSION_ID` environment variable into
Bash-tool subshells, and that the harness includes as `.session_id` in every
status-line and hook payload), the branch, and the `owner/repo` the branch lives
in. Two sessions on the same branch never collide because their session ids
differ; two branches of one session never collide because their slugs and hashes
differ; two repos that both have a branch called `main` never collide because
`owner/repo` is inside the hash.

Exactly one CI file is session-level rather than per-watcher: the finished-PR
list (see "Finished-PR file" below).

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
                          - reads $CLAUDE_CODE_SESSION_ID, cwd and the branch
                          - runs `gh repo view --json nameWithOwner` from cwd and
                            derives SLOT (see "State File Naming")
                          - calls Monitor({command, persistent: true}) with the
                            session id, cwd and branch inlined as literals
                          - writes the returned task id to
                            /tmp/ci_watch_task_<SLOT>
5. watcher runs       → derives the SAME SLOT itself, from its own
                        $CLAUDE_CODE_SESSION_ID + gh repo view + branch
                      → writes /tmp/ci_watch_state_<SLOT> as
                          "<branch>:<state>" every poll
                      → prints notifications to stdout; Monitor relays each
                        line to the session
6. user runs /ci-watcher again, for a SECOND branch (say feat-docs, after a
   second /new-feature):
                      → different branch ⇒ different SLOT ⇒ a second, fully
                        independent watcher. Nothing about the feat-auth watcher
                        is read, stopped, or overwritten.
7. status_line ticks  → status_line.sh hook receives payload with session_id
                      → globs /tmp/ci_watch_state_<session_id>_* and renders ONE
                        row per match, reading each slot's own
                        /tmp/ci_watch_pr_<SLOT> and /tmp/ci_watch_lock_<SLOT>
                      → then one more row from the session-level
                        /tmp/ci_watch_finished_<session_id>
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
│ branches watched: feat/auth AND feat/docs   (two watchers, one session)             │
│ /tmp/ci_watch_state_bbbbbbbb-…_feat_auth-1f2e3d4c5b  "feat/auth:running"            │
│ /tmp/ci_watch_state_bbbbbbbb-…_feat_docs-7a8b9c0d1e  "feat/docs:merging"            │
│ /tmp/ci_watch_pr_bbbbbbbb-…_feat_auth-1f2e3d4c5b     ← watcher writes JSON          │
│ /tmp/ci_watch_pr_bbbbbbbb-…_feat_docs-7a8b9c0d1e     ← watcher writes JSON          │
│ /tmp/ci_watch_finished_bbbbbbbb-bbbb-bbbb-bbbb-…     ← shared by both watchers      │
│ status_line renders one row per slot + the finished row   ← agrees                  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Session Identity

The session id itself is the full session UUID (36 chars including dashes) that
Claude Code's harness injects into every Bash-tool subshell. It is the
SESSION-scoped half of the key; the branch and `owner/repo` supply the rest (see
"State File Naming"). The `/ci-watcher` skill inlines the session id, the cwd and
the branch into the `Monitor` command it launches, and `ci_watch.py` re-derives
the identical slot from them — no slot is ever passed between processes as an
argument, and no inter-process bookkeeping file exists.

### How each consumer gets the key

| Component           | How it gets the key                                                                                                                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/ci-watcher` skill | Reads `$CLAUDE_CODE_SESSION_ID` (env var injected into the Bash-tool subshell), the target branch, and `gh repo view --json nameWithOwner` from cwd; derives `SLOT` itself.                            |
| `ci_watch.py`       | Reads `$CLAUDE_CODE_SESSION_ID` (set explicitly by the Monitor command). Fails loud and exits 2 if unset. Derives `SLOT` from it plus `repo_info()` and its branch argument.                           |
| `status_line.sh`    | Parses `.session_id` from the hook payload (env vars are not available in the status-line context), then DISCOVERS every slot by globbing `ci_watch_state_<session_id>_*`. It never recomputes a hash. |
| `_notify.sh`        | Same discovery glob, through the shared `_ci_watch_session_state_files` helper, for `ci_is_active`.                                                                                                    |
| `session_start.sh`  | Does not need it — the SessionStart hook no longer writes any session-identity files.                                                                                                                  |

Note the asymmetry, and that it is deliberate: the two WRITERS (the skill and
the watcher) compute a slot, which is why the hash must be byte-identical in
bash and python. The two READERS never compute one — they enumerate what exists
and take the slot from the filename.

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

All CI watcher state lives in `/tmp/`. Per-watcher files are keyed on `SLOT`:

```
SESSION        = $CLAUDE_CODE_SESSION_ID                (the full UUID)
IDENTITY       = "<owner>/<repo>#<branch>"              (raw, unsanitized)
IDENTITY_HASH  = first 10 hex chars of sha256(IDENTITY) (over its UTF-8 BYTES)
BRANCH_SLUG    = "<branch, every byte outside [A-Za-z0-9._-] replaced by _,
                   truncated to 40 bytes>-<IDENTITY_HASH>"
SLOT           = "${SESSION}_${BRANCH_SLUG}"
```

```
/tmp/ci_watch_state_<SLOT>      writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_lock_<SLOT>       writer/reader: ci_watch.py (flock'd, holds the owner's PID)
/tmp/ci_watch_pr_<SLOT>         writer: ci_watch.py     reader: status_line.sh
/tmp/ci_watch_<SLOT>.log        writer: redirected STDERR only    readers: humans (tail -f)
                                (stdout is the Monitor event stream, not the log)
/tmp/ci_watch_task_<SLOT>       writer: /ci-watcher skill
                                readers: /ci-watcher stop, stop-all, relaunch
```

One file is SESSION-level, with no branch component:

```
/tmp/ci_watch_finished_<SESSION>  writer: every ci_watch.py of the session
                                  reader: status_line.sh
```

An example slot:
`a3b4c5d6-e7f8-49a0-b1c2-d3e4f5a6b7c8_feat_auth-1f2e3d4c5b`. The slug half is
capped at 40 bytes and the hash at 10, so `BRANCH_SLUG` never exceeds 51 chars
and the whole filename stays well within `PATH_MAX` and the per-component limit.

**Why a hash and not just the sanitized branch.** A pure character substitution
collides (`feat/a` and `feat_a` both become `feat_a`), has no length cap, and
would have to agree between `re.sub` in python and `tr` in bash. Worse, the
branch name alone is not a watcher identity: this repo is worked through git
worktrees, so one session can `cd` between repos mid-session, and two repos can
legitimately have same-named branches. Hashing `"<owner>/<repo>#<branch>"`
answers all of that; the readable slug survives only so a human reading `/tmp`
can tell the files apart.

**Why byte mode on both sides.** `sanitize_branch()` in `ci_watch.py` substitutes
and truncates on the UTF-8 bytes; `_ci_slug()` in `_notify.sh` (and the same
pipeline inlined in `SKILL.md`) uses `LC_ALL=C tr -c 'A-Za-z0-9._-' '_'` and
`LC_ALL=C cut -c1-40`. A codepoint-vs-byte mismatch on a non-ASCII branch name
would make the writer and the launcher key on different files. The hash is
computed over the raw identity's UTF-8 bytes in both languages for the same
reason (`hashlib.sha256(identity.encode())` vs
`printf '%s' "$identity" | shasum -a 256`).

The state file is a **single line** with the format `<branch>:<state>`, e.g.
`feat/auth:running` or `feat__lint:passed`. `status_line.sh` parses it with
`cut -d:` (split on the first colon) so the watcher's branch is available for
display when the user `cd`s to a different branch.

Once a stdout write fails — Monitor auto-stopped the task, or the reader died —
the watcher appends a third field: `<branch>:<state>:monitor-detached@<epoch>`.
It is sticky for the life of the process, because nothing the writer can observe
proves the channel came back. Readers (`status_line.sh`, `ci_is_active`, the
skill's liveness check) strip the field before matching the state value and
report the watcher as alive-but-mute, not as healthy.

State values: `running`, `passed`, `failed`, `conflict`, `behind`, `no-runs`,
`merging`, `merged-passed`, `merged-failed`, `timeout`, `stuck-pending`,
`no-ci`, `no-main-ci`, `no-ci-configured`. `status_line.sh` color-codes them.
The PR cache file is JSON containing url, number, state, mergeable,
mergeStateStatus, mergeCommit and repoUrl, so the status line never calls `gh`
itself. `repoUrl` + `mergeCommit.oid` are what it turns into the "post merge"
hyperlink, `<repoUrl>/commit/<oid>/checks` — GitHub renders a check list for any
commit at that URL, so no run-id tracking is needed.

Atomic writes: every per-watcher file is written via
`tempfile.mkstemp + os.replace` so a slow reader never observes partial content.
The finished-PR file is the one exception, and for a different reason — see
below.

---

## Finished-PR file

`/tmp/ci_watch_finished_<SESSION>` is the session's list of PRs that merged AND
went green on post-merge CI. It is what the status line's `finished PRs: #12,
#7` row is built from.

**Format.** JSON Lines, one PR per line:
`{"number": <int>, "url": "<html_url>", "ts": <unix epoch float>}`.

**Write point.** `ci_watch.py`'s `append_finished_pr()`, called from
`check_all_passed()` on the rising edge of `context == "main"` — the same edge
that fires the `CI PASSED on <default branch>` notification — and called BEFORE
the `merged-passed` state write. That order matters: `status_line.sh` hides
every `merged-passed` row (the PR is meant to appear only in the finished list),
so a crash between the two writes must not be able to drop the PR from both. In
this order the worst case is a duplicate line, which the renderer collapses.

Only `merged-passed` feeds the list. A PR that merged into a repo or branch with
no CI at all (`no-ci-configured`, `no-main-ci`) never had post-merge CI to go
green, so it keeps its own permanent per-PR row instead.

**Append, not rewrite.** The file is opened with
`os.open(..., O_APPEND | O_CREAT | O_WRONLY)` and written with a single
`os.write()` — one real syscall, not Python's buffered `write()`. Several
watchers of one session can finish at the same moment, and an append-only file
has nothing to replace, so there is no temp-file/rename dance and no
read-modify-write window.

**Newest-first and dedup happen at RENDER time,** in `status_line.sh`, not at
write time: entries are sorted by `ts` descending and deduplicated by `number`
keeping the largest `ts`. Physically prepending, or checking for a duplicate
before appending, would each reintroduce the cross-process race the append-only
design exists to avoid. A relaunched watcher on an already-finished PR therefore
appends a second line by design. The reader parses each line on its own and
SKIPS one that fails to parse, which covers a torn write from a killed process.

**Lifetime.** No cleanup path deletes it — not `atexit`, not `/ci-watcher stop`,
not `stop-all`. It grows for as long as `/tmp` keeps it, which in practice is
the life of the session, though nothing actively enforces that boundary.

---

## CI Watcher Lifecycle

### Startup (from `/ci-watcher`)

1. `/ci-watcher` skill runs inside Claude. It reads `$CLAUDE_CODE_SESSION_ID`,
   the repo dir and the target branch (the user's argument, else
   `git branch --show-current`). If the session id or the branch is unset, the
   skill fails loud and exits. It then runs `gh repo view --json nameWithOwner`
   from cwd and derives `SLOT`.
2. Calls `Monitor({command, persistent: true})` with the session id, repo dir,
   and branch inlined into the command as single-quoted literals, and stderr
   appended to `/tmp/ci_watch_<SLOT>.log`. The skill then writes the returned
   task id to `/tmp/ci_watch_task_<SLOT>` atomically (an `mktemp`-unique temp
   file + `mv`; a fixed `.tmp` suffix would let two near-simultaneous launches
   for one slot clobber each other), and only afterwards polls the lockfile (1s,
   max 10 tries) to confirm the watcher actually came up. Persisting before
   verifying is deliberate: a watcher that is alive but slow to appear must
   still be stoppable. On a `DEAD` verdict the skill shows the tail of the log,
   since a dead-on-arrival watcher writes its error to stderr and stderr no
   longer reaches `TaskOutput`.
3. Watcher reads `$CLAUDE_CODE_SESSION_ID`. If unset, exits 2 to stderr
   immediately. It calls `repo_info()` and derives the SAME `SLOT` via
   `slot_for(session_id, owner, repo, branch)` — before taking any lock, so the
   lock it takes is the per-branch one.
4. Watcher takes an `flock` on `/tmp/ci_watch_lock_<SLOT>` and writes its PID
   into it. If a live predecessor holds that lock — which now means the same
   session re-ran `/ci-watcher` **for the same branch in the same repo** — it's
   SIGTERM'd, escalating to SIGKILL if it has not exited within 10s, and the new
   watcher retries; the kernel frees the lock the moment the predecessor dies. A
   predecessor that survives both signals keeps the slot, and the newcomer exits
   3 rather than run a second watcher on it.
5. Watcher writes `<branch>:running` to the state file, registers an `atexit`
   cleanup that unlinks state/pr/lock (never the finished-PR file), and enters
   its main loop.

Two sessions on the same branch each have a different slot, so their
locks/state/pr files are disjoint. So do two branches of ONE session, and so do
two same-named branches in two different repos. None of them ever kill each
other; the only eviction left is same session + same repo + same branch.

### Lifetime

The watcher runs until one of three things happens:

1. `TaskStop` on the stored Monitor task id — from `/ci-watcher stop`,
   `/ci-watcher stop <branch>`, `/ci-watcher stop-all`, or a same-branch
   relaunch.
2. The process exits on its own terminal condition (PR closed without merge, no
   CI on the default branch, main-CI timeout, main CI resolved).
3. The session ends and Monitor tears the `persistent: true` task down.

Case 3 is what makes the old per-loop webhook health check unnecessary: the
harness now owns the "do not outlive the session" guarantee.

### Stop semantics with several watchers

- `/ci-watcher stop` (no argument) stops the CURRENT branch's watcher only. This
  mirrors the launch path, which also defaults to the current branch. Other
  branches' watchers in the same session are untouched.
- `/ci-watcher stop <branch>` stops that branch's watcher. The skill re-derives
  its slot with the same `gh repo view` + hash recipe the watcher used.
- `/ci-watcher stop-all` stops every watcher of the session. It enumerates the
  UNION of `/tmp/ci_watch_task_<SESSION>_*`, `/tmp/ci_watch_lock_<SESSION>_*` and
  `/tmp/ci_watch_state_<SESSION>_*`, so a watcher whose task-id file was reaped —
  or was never written, because the session died before `Monitor` returned — is
  still found through its lock or state file. It reports stopped / already dead /
  survived per slot.

None of them touch `/tmp/ci_watch_finished_<SESSION>`.

Stopping does not depend on the task-id file alone. If
`/tmp/ci_watch_task_<SLOT>` is missing but the lockfile shows a live watcher, the
skill kills that PID directly. The old kill-flag mechanism needed only the
session id, so stop always worked; this keeps that property.

### Status line consumption

`status_line.sh` runs once per status refresh. It:
1. Parses cwd, git_dir, context %, rate-limit fields, and `session_id` from
   the hook payload. If `session_id` is empty, the CI segment is silently
   skipped.
2. Discovers every watcher of the session through `_notify.sh`'s shared
   `_ci_watch_session_state_files` helper — a glob of
   `ci_watch_state_<session_id>_*` — and takes each `SLOT` from the filename. It
   never recomputes a hash.
3. For each slot, splits the state on `:` to get `(stored_branch, state)`, reads
   that slot's own `/tmp/ci_watch_pr_<SLOT>` for PR metadata, and checks that
   slot's own `/tmp/ci_watch_lock_<SLOT>` for liveness. A `merged-passed` slot
   renders NO row — that PR belongs to the finished list instead.
4. Renders one line per surviving slot: `PR #N | ci: <state>`, with `PR #N`
   hyperlinked to the PR. For the post-merge states (`merging`,
   `merged-failed`) the label is `post merge:` instead of `ci:`, and the words
   "post merge" are themselves hyperlinked to
   `<repoUrl>/commit/<mergeCommit.oid>/checks`.
5. Renders one final line from `/tmp/ci_watch_finished_<session_id>`:
   `finished PRs: #12, #7`, newest first, each number hyperlinked to its PR. The
   line is omitted entirely when the file is missing, empty, or every line fails
   to parse.

### Self-cleanup

- **Graceful exit** (SIGTERM or SIGINT, including the `TaskStop` path): the
  `atexit` closure unlinks that slot's state/pr/lock. It never touches another
  slot's files, and never touches the session-level finished-PR file. A
  session-end SIGKILL can skip `atexit` and leave orphan files — the same case
  the `⚠ ci watcher died` rendering already covers.
- **SIGKILL or power-off**: orphan files remain. `status_line.sh` detects this
  via a `kill -0` + `ps` arg-grep on that slot's lock-file PID and renders
  `⚠ ci watcher died` for that row instead of a stale state. Orphan files are
  otherwise harmless because every new session has a different slot prefix.

---

## Multi-Window Topology

### ONE window, one session, SEVERAL branches (what this design adds)

```
Window 1: session_id=11111111-…
          launched /ci-watcher for feat-a, then again for feat-b

Watcher 1: /tmp/ci_watch_state_11111111-…_feat-a-1f2e3d4c5b  "feat-a:running"
Watcher 2: /tmp/ci_watch_state_11111111-…_feat-b-7a8b9c0d1e  "feat-b:merging"
Shared:    /tmp/ci_watch_finished_11111111-…                 both append here
                                  ↑ disjoint slots, one shared finished list

status line:  PR #3011 | ci: running
              PR #3012 | post merge: running
              finished PRs: #3009, #3004
```

Launching watcher 2 does not read, stop, or overwrite ANY of watcher 1's files:
the launch path's stale-task-id handling is scoped to `feat-b`'s own task-id
file. `ci_is_active` reports active while EITHER is running, whatever branch the
shell's cwd happens to be on.

### Two windows, same repo, different branches

```
Window 1: cwd=~/r/.claude/worktrees/feat-a   session_id=11111111-…
Window 2: cwd=~/r/.claude/worktrees/feat-b   session_id=22222222-…

Watcher 1: /tmp/ci_watch_state_11111111-…_feat-a-1f2e3d4c5b   "feat-a:running"
Watcher 2: /tmp/ci_watch_state_22222222-…_feat-b-7a8b9c0d1e   "feat-b:running"
                                  ↑ disjoint on BOTH halves of the key
```

### Two windows, same repo, SAME branch

```
Window 1: cwd=~/r/.claude/worktrees/feat-a   session_id=11111111-…
Window 2: cwd=~/r/.claude/worktrees/feat-a   session_id=22222222-…

Watcher 1: /tmp/ci_watch_state_11111111-…_feat-a-1f2e3d4c5b   "feat-a:running"
Watcher 2: /tmp/ci_watch_state_22222222-…_feat-a-1f2e3d4c5b   "feat-a:running"
                                  ↑ same slug and hash, different session prefix
```

Each window's `status_line.sh` extracts its own `session_id` from its own
payload and globs only its own slots. Each window's `/ci-watcher` reads its own
`$CLAUDE_CODE_SESSION_ID` — different Claude processes have different
session_ids.

### One session, two repos with the SAME branch name

```
Session 11111111-… watches `main` in owner/repo-a, then `main` in owner/repo-b
(a mid-session `cd` between worktrees).

Watcher 1: /tmp/ci_watch_state_11111111-…_main-0c1d2e3f40   "main:running"
Watcher 2: /tmp/ci_watch_state_11111111-…_main-5a6b7c8d9e   "main:running"
                                            ↑ same slug, DIFFERENT hash
```

This is the case the branch slug alone could not separate, and the reason
`owner/repo` is folded into `IDENTITY`.

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
  carry the session id, orphans never collide with new watchers.

- **The finished-PR file is never cleaned up, by anything.** By design (a
  session's finished list must survive every watcher that produced it), but it
  means the file lives until `/tmp` is cleared. It is small — one short JSON
  line per finished PR — and duplicate lines from watcher relaunches are
  collapsed at render time, so the cost is bounded in practice.

- **N concurrent watchers per session is untested at scale.** N `Monitor` tasks
  and N `ci_watch.py` processes in one session is new territory. There is no
  known hard limit in this codebase and no cap is imposed; each watcher polls
  at 1s and they share one GitHub rate limit, so a large N would show up first
  as API throttling.

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

| Question                                           | Answer                                                                                                                                                                                                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| What's the per-watcher file key?                   | `SLOT = "<session UUID>_<branch slug>-<identity hash>"`, where the hash is `sha256("<owner>/<repo>#<branch>")[:10]`.                                                                                                                                                |
| Which file is NOT keyed on the branch?             | `/tmp/ci_watch_finished_<SESSION>` — one shared, append-only finished-PR list per session.                                                                                                                                                                          |
| How does `/ci-watcher` derive the slot?            | `$CLAUDE_CODE_SESSION_ID` from the Bash-tool subshell + the branch + `gh repo view --json nameWithOwner` from cwd.                                                                                                                                                  |
| How does the watcher derive it?                    | The same three inputs: `$CLAUDE_CODE_SESSION_ID` (set explicitly by the `Monitor` command via `env`; exits 2 if unset), its branch argument, and `repo_info()`.                                                                                                     |
| How does `status_line.sh` get the slots?           | It does not compute any. It parses `.session_id` from its hook payload, then globs `ci_watch_state_<session_id>_*` and takes each slot from the filename.                                                                                                           |
| What's the state-file content?                     | A single line `<branch>:<state>` (e.g. `feat/auth:passed`).                                                                                                                                                                                                         |
| Can one session watch several branches?            | Yes — one watcher per branch, one status-line row each, all independent.                                                                                                                                                                                            |
| What stops two watchers from colliding?            | `flock` on `/tmp/ci_watch_lock_<SLOT>` — kernel-arbitrated, released automatically when the holder dies. Paths are disjoint across sessions, branches and repos; only a same-session/same-repo/same-branch relaunch evicts the predecessor (SIGTERM, then SIGKILL). |
| What stops the watcher from outliving the session? | Monitor's `persistent: true` task ends when the session ends; `TaskStop` ends it early.                                                                                                                                                                             |
| How is a PR removed from the status line?          | It isn't removed — once its post-merge CI goes green its own row disappears and it joins the `finished PRs:` row instead.                                                                                                                                           |
