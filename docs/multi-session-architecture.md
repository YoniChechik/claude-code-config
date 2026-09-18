# Multi-Session Architecture

How `~/.claude/` handles multiple Claude Code sessions running simultaneously
across multiple terminal windows, multiple repos, and multiple feature worktrees.

This is an internal design doc. It describes what the code actually does today,
keyed off `session_start.sh`, the `post_tool_use__ci_watch_trigger.sh` hook, the
`/ci-watcher` skill, and `ci_watch_once.sh`.

---

## Overview

The user runs many Claude Code windows at once: a window on `main` in repo-A,
a window on `feat/auth` in a worktree of repo-B, a second window on `main` in
repo-B, and so on. Each is an independent Claude process with its own
`session_id`. On top of that, one session can trigger several watchers at
once — a session that pushes to one branch and merges another runs a `push`
watcher and a `merge` watcher concurrently.

The old design (a single always-on `ci_watch.py` daemon per branch, launched
via `Monitor({persistent: true})` and kept alive for the life of the session)
is gone. `ci_watch_once.sh` is a **one-shot** script: it runs exactly once,
to exactly one real CI result, and exits — no re-arm, no phase-cursor file,
no daemon to protect from being auto-killed. It comes in two independently
triggered **kinds**:

- **`push`** — tracks one push's pre-merge CI checks to a verdict (pass, fail,
  or "no checks configured"), then exits.
- **`merge`** — waits for the PR to actually merge, then tracks the resulting
  post-merge CI run(s) on the default branch to a verdict, then exits.

Both are launched the same way: a Bash tool call with `run_in_background:
true` (never `Monitor` — see "Why Bash, not Monitor" below) and no `timeout`
override, so the watcher runs to a real end state rather than a time box.

The mechanism that makes concurrent watchers not collide: every watcher's
`/tmp` files are keyed on `(owner/repo, branch, kind)` — **not** on the
session. A push watcher for `feat/auth` and a merge watcher for `feat/auth`
use different files entirely (different `kind`) and never contend with or
evict each other. Two watchers of the *same* kind for the *same* branch
(from the same session relaunching, or from two different sessions/terminals)
contend for the *same* lock, and the newer one evicts the older — this is
intentional and cross-session, because a stale watcher for an old
push/merge is stale everywhere, not just within the session that started it.

---

## Why Bash, not Monitor

The prior design launched `ci_watch.py` via `Monitor({command, persistent:
true})`. Two things changed that:

1. **`Monitor` no longer supports `persistent: true`.** Its schema caps
   `timeout_ms` at 1,800,000 (30 minutes) with no bypass: every arm expires
   and must be manually re-armed. A script designed to run for hours (a slow
   CI pipeline, a `gh pr merge --auto` that takes a while to actually land)
   would need Claude to notice each 30-minute expiry and re-arm it forever
   just to keep watching — the opposite of "launch once, forget about it."
2. **Bash `run_in_background: true` has no such cap.** Verified empirically:
   a backgrounded command that ran for a full 150 real seconds delivered its
   completion notification only once it actually finished — well past the
   Bash tool's 120s/600s *foreground*-call timeout, which does not apply to
   backgrounded tasks. A script built to run to a real end state (not loop
   forever) fits this model directly: one Bash call, one completion
   notification, whenever that actually happens.

The one caveat, unchanged from the old design: a backgrounded task's lifetime
is still bounded by the host Claude Code process staying alive. A closed
terminal or a slept machine ends either mechanism equally — this is not a
regression, just the same real-world limit the daemon always had.

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
4. claude runs `git push`
                      → PostToolUse:Bash fires post_tool_use__ci_watch_trigger.sh
                      → hook sees a successful, narrowed-shape `git push`,
                        checks `gh pr view` shows an OPEN pr, and returns
                        additionalContext instructing Claude to launch the
                        push watcher
                      → Claude calls Bash with
                        `ci_watch_once.sh push 'feat-auth'` and
                        run_in_background: true, then writes the returned
                        task_id to /tmp/ci_watch2_task_<SESSION>_push_<slug>-<KEY>
5. watcher runs       → derives the SAME (owner/repo, branch, kind) key itself
                        via `gh repo view` + its own arguments
                      → acquires LOCKFILE via `lockf -t 0 -k`, writes PIDFILE
                      → blocks on `gh pr checks --watch --fail-fast` (after a
                        short check-registration grace)
                      → prints exactly ONE line to stdout, then exits; the
                        Bash background task's completion notification
                        relays it to the session
6. claude runs `gh pr merge`
                      → same hook fires again, this time on the narrowed
                        merge shape → instructs a `merge`-mode launch instead
                      → different kind ⇒ different LOCKFILE ⇒ fully
                        independent from the push watcher; nothing about it
                        is read, stopped, or overwritten
7. merge watcher runs → waits (bounded, 6h) for the PR to actually merge,
                        then finds and watches the post-merge run(s) on the
                        default branch, then exits with its own report(s)
```

ASCII view of two windows running at the same time:

```
┌─ Window A ──────────────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-a              session_id: aaaaaaaa-aaaa-aaaa-aaaa-…                    │
│ branch: main                                                                        │
│ No watcher running → no /tmp/ci_watch2_*                                            │
└─────────────────────────────────────────────────────────────────────────────────────┘

┌─ Window B ──────────────────────────────────────────────────────────────────────────┐
│ cwd: ~/repo-b/.claude/worktrees/feat-auth   session_id: bbbbbbbb-bbbb-bbbb-bbbb-…   │
│ push watcher for feat/auth AND merge watcher for feat/docs, both running at once     │
│ /tmp/ci_watch2_lock_push_feat_auth-1f2e3d4c5b   ← kernel-held by the push watcher   │
│ /tmp/ci_watch2_pid_push_feat_auth-1f2e3d4c5b    ← its eviction-target pgid          │
│ /tmp/ci_watch2_lock_merge_feat_docs-7a8b9c0d1e  ← kernel-held by the merge watcher  │
│ /tmp/ci_watch2_task_bbbbbbbb-…_push_feat_auth-1f2e3d4c5b   ← this session's bookkeeping│
│ /tmp/ci_watch2_task_bbbbbbbb-…_merge_feat_docs-7a8b9c0d1e  ← this session's bookkeeping│
│ Each watcher reports once, on its own, via a Bash background-task notification.      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## The Key

Every watcher's files are keyed on `(owner/repo, branch, kind)` — global,
never scoped to a session:

```
OWNER_REPO = "<owner>/<repo>"                             (from `gh repo view`)
KEY        = first 10 hex chars of sha256("OWNER_REPO#branch")
SLUG       = branch, every byte outside [A-Za-z0-9._-] replaced by _,
             truncated to 40 bytes
KIND       = "push" | "merge"
```

`_ci_watch_key` (in `scripts/_notify.sh`) computes `KEY` from `OWNER_REPO` and
`branch` — it takes no `kind` argument and no session argument. `_ci_slug`
computes `SLUG` from `branch` alone (unchanged from before). Every caller —
the watcher script itself, the hook, the `/ci-watcher` skill's manual
commands, `/ci-watcher stop` — composes its own filename as
`<component>_<KIND>_<SLUG>-<KEY>`, so the hash function has exactly one
implementation and kind-scoping lives in the filename convention, never in
duplicated hashing logic.

**Why global, not per-session.** A stale push watcher for an old commit, or a
stale merge watcher for a PR that already merged, is stale for *every*
session watching that branch, not just the one that launched it. Keying
globally means a second push to the same branch — whichever session or
terminal makes it — always supersedes the branch's existing push watcher,
which is the correct behavior: there is only ever one "current" answer for
"did the latest push's CI pass," and it should not depend on which terminal
asks.

**Why `owner/repo` is still folded in.** The same reason as before: this
repo is worked through git worktrees, so one session can `cd` between repos
mid-session, and two repos can legitimately have same-named branches. Hashing
`"<owner>/<repo>#<branch>"` prevents two unrelated branches called `main` in
different repos from colliding.

### The four files per watcher

```
/tmp/ci_watch2_lock_<KIND>_<SLUG>-<KEY>        the lockf(1) lock file itself
/tmp/ci_watch2_pid_<KIND>_<SLUG>-<KEY>         informational: pgid/start/session
/tmp/ci_watch2_<KIND>_<SLUG>-<KEY>.log         diagnostic log (gh/git chatter, stderr)
/tmp/ci_watch2_task_<SESSION>_<KIND>_<SLUG>-<KEY>   per-session task-id bookkeeping
```

The first three are global (no session component) and shared by whichever
session is currently running that `(branch, kind)`'s watcher. Only the fourth
carries a session id, because it exists purely so `/ci-watcher stop-all` can
find and `TaskStop` the Bash background tasks *this specific session*
launched — it is written by whichever agent code path issued the
`run_in_background` call (the hook's instructions, or the skill's manual
commands), never by the watcher script itself, since a script cannot know the
external `task_id` the Bash tool assigns to its own invocation.

---

## Locking: `lockf`, not a hand-rolled scheme

The lock is a real, kernel-mediated advisory lock via macOS's `lockf(1)`
(`flock(2)`-based), not a hand-rolled PID-file convention. This was a
deliberate choice after three rounds of finding real races in earlier,
hand-rolled designs (`flock` the *CLI tool* does not exist on macOS; a
`mkdir`+`ln`+PID-content scheme had a claim-gate that never re-validated
ownership, a stale-claim sweep with no generation token, and a PID-identity
check that was a heuristic, not a guarantee, with an unavoidable TOCTOU
window before every signal). `lockf` eliminates all of that as a *category*,
not by patching each instance: the lock is tied to a live process's open file
descriptor, and the kernel — not a value some script reads and
re-interprets — is the sole arbiter of whether it is held. It is
automatically and atomically released the instant the holder dies, by *any*
means: normal exit, `SIGTERM`, `SIGKILL`, or a crash. There is no stale-lock
state to detect and no PID-reuse ambiguity to guard against.

**Acquire.** The watcher's real body runs *as* `lockf`'s `command` argument:
`lockf -t 0 -k "$LOCKFILE" bash "$SELF" "$MODE" "$BRANCH" "$BODY_SENTINEL"`.
`-t 0` fails immediately (no blocking) if the lock is already held, with exit
code 75 (`EX_TEMPFAIL`) — the *only* code this driver treats as "someone else
holds it"; every other exit code is the body's own real, completed outcome
and is passed straight through. `-k` keeps the lock file in place after the
command exits, so the same path is reusable for the next launch.

**`PIDFILE` is purely informational.** The moment the body starts running
(and therefore knows it holds the lock), it writes `PIDFILE` with its own
process-group id, a start timestamp, and the session id — an atomic
`mktemp`-then-`mv` write. This file exists *only* to give a would-be evictor
something to aim a signal at. If it is stale, wrong, or missing, the worst
outcome is a wasted or missing signal — **never** a lock-safety violation,
because `lockf`/the kernel remains the sole source of truth for whether the
lock is actually free.

**Eviction (on `EX_TEMPFAIL` only).** Read `PIDFILE` for the recorded pgid.
If present: `kill -TERM -- -<pgid>` (a *negative* pgid — see `run_watchable`
below for why every watcher runs as its own process group), then poll the
**lock itself** (`lockf -t 0 -k "$LOCKFILE" true`, every 1s for up to 10s) for
it becoming free — polling the lock is the only authoritative signal that
eviction worked, never a guess about whether some possibly-reused pgid is
still alive. Still held after 10s → `SIGKILL` the group, probe briefly again.
Retry the real acquire, bounded to 5 total attempts; on exhaustion, print one
line and exit nonzero. If `PIDFILE` is missing or unreadable when eviction is
needed: there is no target to signal — a documented residual limitation, not
a bug — so instead poll the lock alone for up to 30s hoping the holder
finishes on its own, then give up the same way.

---

## `run_watchable`: process-group signaling, TERM only

Every blocking child the watcher runs — both `gh --watch` calls and every
poll-loop `sleep` — goes through `run_watchable`, which:

- Sets `set -m` at the top of the script so a backgrounded job gets its own
  process group (pgid = the job's own PID), meaning `gh` and anything *it*
  spawns all land in that same group. A single `kill -TERM -- -<pgid>` then
  reaches the whole tree, not just the direct child — this is what makes
  eviction actually kill `gh`'s own children too, not just `gh` itself.
- Installs its `TERM` trap *before* backgrounding the command, so a signal
  arriving in that gap cannot fall through to the shell's default action.
- Polls with `sleep 0.2` in a loop, not a blocking `wait` — `wait` proved
  unreliable here (see below); `sleep` is far more consistently interruptible
  by a trapped signal across bash versions. `wait` is only ever called once
  the loop has already confirmed (via `kill -0`) that the job is truly gone,
  purely to reap it and read its real exit status.
- On a caught signal, polls again (bounded, 5×1s) for the group to actually
  disappear before declaring done, escalating to `SIGKILL` on the group if it
  has not — a real reap-and-verify step, not just "send a signal and hope."
- Returns one of exactly two outcomes: the watched command's own real exit
  code (nothing interrupted it), or 143 (we sent `TERM`). Never one hardcoded
  value regardless of cause.

**Only `SIGTERM` is trapped — there is no `SIGINT` handling.** This is a
deliberate scope narrowing discovered during implementation, not an
oversight: nothing in this design ever sends a watcher `SIGINT` — eviction
and `/ci-watcher stop` both use `TERM` then, if needed, `KILL`. A `SIGINT`
trap was implemented and then removed after empirical testing showed it
could never fire: a signal that is already `SIG_IGN` "on entry" to a shell
can never be trapped by that shell (a POSIX/bash rule), and that is exactly
the disposition a backgrounded, non-interactive process gets unless its
*parent* shell enables real job control before forking it — a guarantee a
backgrounded Bash-tool invocation, with no controlling terminal, cannot make.
Chasing that guarantee would have tested an environment property nobody
controls, for a signal nothing in this system ever sends.

**Why not plain `wait`.** The original design used `wait "$watch_pgid"`
directly and relied on it unblocking when the trap ran. Empirically, on this
platform, a caught `SIGINT` left `wait` parked forever even though the trap
itself never fired at all (see above) — and separately, `wait`'s
interruption semantics under `set -m` job control are not something this
design wants to depend on for correctness at all, for *any* signal. Polling
with `sleep` sidesteps the question entirely: the loop simply notices, within
~0.2s, either that the job is gone or that a trap set a flag.

---

## CI Watcher Lifecycle

### `push` mode

1. **Check-registration grace** (default 45s, 5s poll, all overridable via
   env vars for tests): right after a push or `gh pr create`, GitHub may not
   have registered check suites yet, so an immediate "no checks" would be a
   lie a few seconds early. Poll `gh pr view --json statusCheckRollup` until
   it gains entries, or until the grace window elapses.
2. **Block on the verdict**: `gh pr checks "$BRANCH" --watch --fail-fast`.
   Pass → `CI passed for <branch>`. Fail → `CI FAILED for <branch>` (reporting
   a red CI is the watcher's job *done*, not the watcher failing — exit 0
   either way). `gh pr checks` shares exit 1 between "genuinely failed" and
   "no checks reported"; since step 1 already ruled out the latter unless
   checks vanished mid-run, only the literal output text can still claim it.
3. Exit. No merge-wait, no post-merge phase — a push watcher's job ends here.
   (The old design chained push→merge-wait→post-merge in one script; splitting
   them into independent kinds removed a real bug where a merge-triggered
   relaunch would evict and kill an in-flight push watcher, since they now
   use different `LOCKFILE`s entirely.)

### `merge` mode

1. **Merge-wait** (default 6h bound, 20s poll): `gh pr merge --auto` returns
   success long before the PR is actually merged, so the real merge is what
   this phase polls for. `MERGED` → proceed. `CLOSED` (not merged) → report
   and exit. Still `OPEN` past the bound → report the timeout with a
   `/ci-watcher merge <branch>` retry instruction, and exit. The bound is a
   concrete, freshly-chosen constant (not inherited from `Monitor`'s old
   30-minute cap) — long enough to cover a slow CI pipeline across a full
   working day, short enough to bound a forgotten/leaked process to a
   concrete lifetime rather than leaving it truly infinite.
2. **Post-merge discovery** (default 120s appearance grace, 20-run snapshot
   cap): resolve the default branch, then poll `gh run list` for the first
   run(s) on the merge commit. Nothing found within the grace window →
   report and exit. Otherwise take **one snapshot** (never re-polled) of up
   to 20 run ids and watch each once, announcing pass/fail per run. A run
   that registers after that snapshot, or a fan-out past 20, is an accepted
   scope limit — not a design gap this system tries to close.
3. Exit 0 regardless of the verdicts — reporting them *is* the successful job.

### Error handling

Every `gh`/`git` call is classified as terminal success, terminal failure (a
real, reportable outcome — a red CI, a closed PR), or a retryable error (auth
failure, rate limit, transient network error, malformed/empty JSON, or the
call itself timing out). Retryable errors get up to 3 local retries with a
5s fixed backoff before escalating to one stdout line and a nonzero exit.
Each call's raw output is captured into a fresh per-call temp file for
classification, then appended to the watcher's log — never classified by
grepping a shared log tail that could still hold a previous invocation's
leftover text. Some call sites declare specific exit codes as *always*
terminal (`gh pr checks --watch`/`gh run watch --exit-status` both use exit 1
to mean "CI is red"), checked before any text matching, so a CI job literally
named `timeout-probe` can never be misread as a transient timeout and retried
into a false pass.

---

## Stop semantics

- **`/ci-watcher stop <branch> [push|merge]`** reads `PIDFILE` for the
  matching kind(s) of that branch and signals the recorded process group
  directly: `SIGTERM` → poll the lock (10s) → `SIGKILL` → poll again (5s).
  This is **cross-session by design** — `PIDFILE` ownership carries no
  session scoping, so this works even against a watcher launched by a
  different terminal, or one whose launching session has since exited. If
  `PIDFILE` is missing or stale, this degrades to the same residual
  limitation as the lock's own eviction path: no target to signal, so it
  falls back to polling the lock alone.
- **`/ci-watcher stop-all`** is scoped strictly to *this session's own*
  task-id files (`/tmp/ci_watch2_task_<SESSION>_*`) and `TaskStop`s them one
  by one. It never reaches into another session's currently-owned watcher,
  even one this session originally launched and was later superseded on (a
  relaunch from anywhere overwrites that key's task-id file the next time
  *this* session launches it, but does not retroactively touch a task-id
  another session wrote for the same key). A task-id whose task has already
  finished is inert — `TaskStop`ing it is a harmless no-op.
- **Never automatic.** A watcher runs to a real end state on its own and
  needs no supervision; nobody should call `/ci-watcher stop`,
  `/ci-watcher stop-all`, or `TaskStop` on a watcher's task id without an
  explicit user request.

---

## Multi-Window Topology

### One window, one session, a push watcher AND a merge watcher for the SAME branch

```
Window 1: session_id=11111111-…, branch=feat-auth
          pushed (push watcher launched), then merged (merge watcher launched)

/tmp/ci_watch2_lock_push_feat-auth-1f2e3d4c5b    ← push watcher's lock
/tmp/ci_watch2_lock_merge_feat-auth-1f2e3d4c5b   ← merge watcher's lock — DIFFERENT file
                                  ↑ different kind ⇒ never contend, coexist freely
```

### Two sessions, same repo, same branch, SAME kind

```
Session A pushes to feat-auth → launches a push watcher, acquires the lock.
Session B (a different terminal, or a relaunch by A) pushes again to
feat-auth → tries to acquire the SAME LOCKFILE, gets EX_TEMPFAIL, evicts
Session A's watcher by its recorded pgid, and takes over.

                                  ↑ intentional and cross-session: the newer
                                    push is the only one worth watching
```

### Two windows, same repo, different branches

```
Window 1: cwd=~/r/.claude/worktrees/feat-a   session_id=11111111-…
Window 2: cwd=~/r/.claude/worktrees/feat-b   session_id=22222222-…

/tmp/ci_watch2_lock_push_feat-a-1f2e3d4c5b   ← disjoint KEY (different branch)
/tmp/ci_watch2_lock_push_feat-b-7a8b9c0d1e   ← disjoint KEY
```

### One session, two repos with the SAME branch name

```
Session 11111111-… watches `main` in owner/repo-a, then `main` in owner/repo-b
(a mid-session `cd` between worktrees).

/tmp/ci_watch2_lock_push_main-0c1d2e3f40   ← same slug, DIFFERENT hash
/tmp/ci_watch2_lock_push_main-5a6b7c8d9e
```

This is the case the branch slug alone could not separate, and the reason
`owner/repo` is folded into the key.

---

## Known Limitations / Gaps

- **The hook's trigger contract is intentionally narrow.** A regex/case-based
  hook cannot reliably parse arbitrary shell. It only fires on the simple,
  overwhelmingly common forms: bare `git push`/`git push -f`/`git push
  --force[-with-lease]`/`git push origin <currentbranch>` with no `-C`, no
  explicit differing branch/refspec, no multi-ref push; bare `gh pr
  create`/`gh pr create --head <currentbranch>` with no `--repo`; bare `gh pr
  merge`/`gh pr merge --auto` with no explicit PR number/URL/`--repo`.
  Anything else — compound commands, `-C`, `--repo`, an explicit differing
  branch, a PR number/URL, a multi-branch push — is silently skipped: no
  trigger, no guess. `/ci-watcher [branch]` / `/ci-watcher merge [branch]`
  are the manual fallback.
- **Cross-session `stop` signals by pgid, not `TaskStop`.** This is what lets
  it work even after the launching session has exited, but it degrades to
  lock-probe-only polling (no signal sent) if `PIDFILE` is stale or missing —
  a residual limitation of a purely informational file, stated plainly
  rather than hidden.
- **Fixed timing constants, not user-configurable without an edit**: the
  6-hour merge-wait bound, the 120-second post-merge run-appearance grace,
  and the 20-run discovery snapshot cap are all constants in the script
  (overridable by env var for tests, not by end-user configuration).
- **Stale task-id files are not background-garbage-collected**, only cleaned
  up opportunistically the next time `/ci-watcher` runs in that session.
  Unbounded accumulation across a very long-lived session is an accepted,
  documented limitation, not an oversight.
- **The per-key diagnostic log is never rotated or truncated.** It grows for
  as long as a given `(branch, kind)` gets relaunched. Simple rotation would
  be a cheap follow-up, not something this design currently does.
- **A `gh pr merge <number>` run from an unrelated branch could evict the
  wrong branch's merge watcher.** The hook resolves the target branch from
  its own `cwd`'s `git branch --show-current`, not from the PR number in the
  command — an accepted, narrow known limitation, not a design gap.
- **`session_start.sh` runs `git fetch -p` and `git merge --ff-only` on every
  start.** Two simultaneous sessions in the same base dir will race here;
  git's ref-locking handles it but worst case one sees "Already up to date."

---

## Quick reference

| Question                                               | Answer                                                                                                                                                                                                    |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| What's the per-watcher file key?                       | `(owner/repo, branch, kind)` — global, never scoped to a session. `KEY = sha256("<owner>/<repo>#<branch>")[:10]`, filenames are `<component>_<kind>_<slug>-<KEY>`.                                        |
| Which file DOES carry a session id?                    | Only the task-id bookkeeping file, `ci_watch2_task_<SESSION>_<kind>_<slug>-<KEY>` — used solely by `/ci-watcher stop-all` to find this session's own Bash background tasks.                               |
| How does a watcher get launched?                       | A Bash tool call with `run_in_background: true`, no `timeout` override — from the `PostToolUse:Bash` hook's `additionalContext`, or a manual `/ci-watcher`/`/ci-watcher merge` command.                   |
| What stops two same-kind watchers from colliding?      | `lockf(1)` — kernel-mediated, released automatically the instant the holder dies by any means. A same-branch, same-kind relaunch evicts the predecessor by its recorded pgid (`SIGTERM`, then `SIGKILL`). |
| Do a push watcher and a merge watcher ever collide?    | No — different `kind` means a different `LOCKFILE`; they never contend or evict each other, even for the same branch.                                                                                     |
| What stops the watcher from outliving the session?     | Nothing special — it runs to its own real end state and exits on its own. The host Claude Code process staying alive is the only outer bound, same as the old daemon's `Monitor` lifetime was.            |
| How is `SIGINT` handled?                               | It isn't — only `SIGTERM` is trapped. Nothing in this design ever sends a watcher `SIGINT`, and a signal already `SIG_IGN` on entry to a backgrounded, non-interactive shell can never be trapped by it.  |
| How does `/ci-watcher stop <branch>` find the process? | Reads `PIDFILE` for the recorded process-group id and signals it directly — cross-session, since `PIDFILE` carries no session scoping.                                                                    |
