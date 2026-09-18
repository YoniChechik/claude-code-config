---
name: "ci-watcher"
description: "Launch or stop a one-shot CI watcher for a branch. `/ci-watcher [branch]` watches the branch's PR checks, `/ci-watcher merge [branch]` watches the merge and the post-merge run, `/ci-watcher stop <branch>` stops that branch's watchers, `/ci-watcher stop-all` stops every watcher this session launched."
argument-hint: "[branch|merge [branch]|stop <branch> [push|merge]|stop-all]"
---

A CI watcher is a ONE-SHOT background process: `ci_watch_once.sh push '<branch>'`
or `ci_watch_once.sh merge '<branch>'`. It runs once, start to finish, prints its
result on stdout, and exits. There is no daemon, no re-arm and no persistence.

- **push mode** — waits for the branch's PR checks to settle, then reports once:
  `CI passed for <branch>` / `CI FAILED for <branch>` / `No CI checks configured
  for <branch>`, and exits.
- **merge mode** — waits for the PR to really merge (bounded at 6h), then
  discovers the post-merge run(s) on the default branch and reports one line per
  run, then exits.

The two modes are independent. A push watcher and a merge watcher for the SAME
branch run side by side and never disturb each other, because every `/tmp` file
is keyed on `(owner/repo, branch, kind)` — see "the KEY" below.

One session can hold SEVERAL watchers at once: several branches, and both kinds
per branch. Launching one never disturbs another.

**Tool availability:** `TaskStop` is a deferred tool in this harness. If it is
not already available, load it first with `ToolSearch` query `select:TaskStop`.

# the hook launches watchers automatically

`scripts/post_tool_use__ci_watch_trigger.sh` (a `PostToolUse:Bash` hook) launches
the right watcher on its own, with no `/ci-watcher` invocation, right after:

- a `git push` of the current branch that already has an OPEN PR → push watcher,
- a `gh pr create` for the current branch → push watcher,
- a `gh pr merge` of the current branch's PR → merge watcher.

## the trigger contract is INTENTIONALLY narrow

A hook cannot reliably parse arbitrary shell, so it does not try. It triggers
ONLY on the simple forms whose target is unambiguously "the current branch of the
repo at the hook's own cwd", and silently skips everything else:

- bare `git push`, `git push -f`, `git push --force[-with-lease]`, or
  `git push <remote> <currentbranch>`. Skipped: `git -C <dir> push`, any
  `src:dst` refspec, a branch delete, a multi-ref push, any other flag, and a
  push whose output says `Everything up-to-date`.
- bare `gh pr create`, or `gh pr create --head <currentbranch>`. Skipped:
  `--repo`, a positional argument, a differing `--head`.
- bare `gh pr merge` or `gh pr merge --auto`. Skipped: `--repo` and any explicit
  PR number, URL or branch selector.
- Anything that is not ONE simple command (a `&&` chain, a pipeline, a command
  substitution, a redirect) is skipped, and so is any command that did not exit
  0 or that carries `-h`/`--help`.

This is a deliberate limitation, not a gap to close: a wrong-target watch is far
worse than no watch. **The manual commands below are the fallback** whenever the
hook did not fire.

# RULE: never stop a watcher on your own initiative

Never run `/ci-watcher stop`, `/ci-watcher stop-all`, `TaskStop` on a watcher's
task id, `kill`, or any equivalent, unless the USER explicitly asked for it —
by typing `/ci-watcher stop` or saying something like "stop the ci watcher".

A watcher needs no supervision. It reaches a real end state on its own (CI
verdict, no checks, PR closed, post-merge runs reported, merge-wait timeout,
persistent error) and exits by itself the instant it has that result. There is
nothing to protect it from and nothing to tidy up after it.

Relaunching is not a kill: launching a new watcher of the same kind for the same
branch is always safe. The new one evicts the stale one through the lock
protocol, automatically.

# the KEY: how every `/tmp` file is keyed

- `OWNER_REPO` = `<owner>/<repo>`, from `gh repo view` in the CURRENT directory.
- `KEY` = the first 10 hex chars of `sha256("<owner>/<repo>#<branch>")`.
- `SLUG` = the branch name, made filename-safe and cut to 40 chars.
- `KIND` = the literal string `push` or `merge`.

The KEY is GLOBAL — it carries no session id. A watcher for a branch is the same
watcher in every session and every terminal on the machine, which is exactly why
a stale one can always be superseded.

The four files per `(kind, branch, repo)`:

- `/tmp/ci_watch2_lock_<kind>_<slug>-<KEY>` — the `lockf(1)` lock file itself.
  The kernel holds this lock for exactly as long as the watcher body runs, and
  releases it the instant the holder dies by ANY means. It is the single source
  of truth for "is a watcher of this kind running for this branch".
- `/tmp/ci_watch2_pid_<kind>_<slug>-<KEY>` — INFORMATIONAL only:
  `pgid=<pgid> start=<epoch> session=<session id>`. It exists to AIM an eviction
  signal, never to decide whether the lock is held. A stale, wrong or missing
  value costs at worst a wasted or missing signal.
- `/tmp/ci_watch2_<kind>_<slug>-<KEY>.log` — the diagnostic log. Every `gh`/`git`
  line goes here; stdout carries the notification lines alone.
- `/tmp/ci_watch2_task_<SESSION>_<kind>_<slug>-<KEY>` — per-session bookkeeping:
  the Bash background `task_id` of the watcher THIS session launched. Only
  `/ci-watcher stop-all` reads it.

`_ci_watch_key` and `_ci_slug` in `~/.claude/scripts/_notify.sh` are THE single
implementation of the KEY and SLUG recipes — `ci_watch_once.sh` and the hook both
source that file. Never re-inline the `shasum`/`tr`/`cut` pipeline here; a second
copy would drift and would name files no watcher ever creates.

Run this block FIRST in every flow below — launch, `stop` and `stop-all`. Run it
from the repo directory whose branch you are targeting: `owner/repo` comes from
`gh repo view` in the CURRENT directory, so a `stop` run from repo A can never
derive the key of a watcher in repo B.

Use the printed `BRANCH=`, `SLUG=` and `KEY=` values verbatim below — `BRANCH` is
whitespace-stripped exactly as `ci_watch_once.sh` strips its own argument, and an
unstripped copy would hash to a different KEY:

```bash
# BRANCH: preset it for an explicit branch argument; otherwise use the current
# branch. Inline a user-supplied branch as a SINGLE-quoted literal
# (BRANCH='feat/x'), never through double quotes — see the quoting rule in the
# launch step.
BRANCH="${BRANCH:-$(git branch --show-current)}"
# Strip leading/trailing whitespace, exactly as ci_watch_once.sh does to $2. A
# pasted branch name with a trailing space would otherwise hash HERE to a key
# the watcher itself never computes, and every lock and stop would miss it.
BRANCH="${BRANCH#"${BRANCH%%[![:space:]]*}"}"
BRANCH="${BRANCH%"${BRANCH##*[![:space:]]}"}"
if [[ -z "$BRANCH" ]]; then
    echo "Error: no branch resolved; cannot key the ci watcher files." >&2
    exit 1
fi
# THE single bash implementation of the KEY and SLUG recipes. owner/repo is part
# of the identity, so two worktrees of different repos that share a branch name
# still get two distinct keys. _ci_watch_key fails loudly if the hash cannot be
# computed.
# shellcheck source=/dev/null
source ~/.claude/scripts/_notify.sh
OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
KEY=$(_ci_watch_key "$OWNER_REPO" "$BRANCH") || exit 1
SLUG=$(_ci_slug "$BRANCH")
echo "BRANCH=${BRANCH}"
echo "DIR=$(pwd)"
echo "SLUG=${SLUG}"
echo "KEY=${KEY}"
```

# step 0: handle `stop` and `stop-all`

Both stop watchers and exit — do NOT launch anything afterwards. Run either one
ONLY on an explicit user request (see the RULE above).

## `/ci-watcher stop <branch> [push|merge]`

This signals the recorded OS process group directly, read from `PIDFILE`. It is
CROSS-SESSION by design: `PIDFILE` ownership is not scoped to a session, so this
stops the branch's watcher whichever session launched it — which is the point,
since a stale watcher is stale everywhere.

Run the KEY block with `BRANCH='<branch>'` preset. Then, for BOTH kinds (or only
the one kind the user named):

```bash
# KIND is 'push' or 'merge'. Repeat this block once per kind to stop.
PIDFILE="/tmp/ci_watch2_pid_${KIND:?}_${SLUG:?run the KEY block first}-${KEY:?}"
LOCKFILE="/tmp/ci_watch2_lock_${KIND}_${SLUG}-${KEY}"
# Nothing holds the lock -> there is no watcher of this kind. Say so and stop.
if lockf -t 0 -k "$LOCKFILE" true 2>/dev/null; then
    echo "NOT-RUNNING ${KIND}"
    exit 0
fi
# The lock IS held. Read the pgid the holder recorded for us to aim at.
PGID=$(tr ' ' '\n' <"$PIDFILE" 2>/dev/null | grep '^pgid=' | head -n 1)
PGID=${PGID#pgid=}
case "$PGID" in '' | *[!0-9]*) PGID="" ;; esac
if [[ -z "$PGID" ]]; then
    # Residual limitation, identical to the lock design's own eviction path:
    # with no recorded target there is NOTHING to signal. All we can do is poll
    # the lock and hope the holder finishes on its own.
    echo "NO-TARGET ${KIND} (pid file missing or stale; polling the lock only)"
else
    # Negative pgid: the signal reaches the watcher, its lockf parent and every
    # gh child in one shot.
    kill -TERM -- -"$PGID" 2>/dev/null
fi
# The lock CLEARING is the only authoritative proof the watcher is gone — never
# a guess about whether some (possibly reused) pgid is still alive. Poll it for
# 10 seconds, then escalate.
for _ in $(seq 1 10); do
    lockf -t 0 -k "$LOCKFILE" true 2>/dev/null && { echo "STOPPED ${KIND}"; exit 0; }
    sleep 1
done
if [[ -n "$PGID" ]]; then
    kill -KILL -- -"$PGID" 2>/dev/null
    for _ in $(seq 1 5); do
        lockf -t 0 -k "$LOCKFILE" true 2>/dev/null && { echo "KILLED ${KIND}"; exit 0; }
        sleep 1
    done
fi
echo "STILL-HELD ${KIND}"
```

Report one line per kind: stopped / killed / not running / still held. If a kind
reports `NO-TARGET` and then `STILL-HELD`, tell the user plainly: the watcher is
alive, `PIDFILE` names no process to signal, so it was left to finish on its own.

Then drop this session's task-id files for that branch, if any — they can only be
stale now:

```bash
rm -f "/tmp/ci_watch2_task_${CLAUDE_CODE_SESSION_ID:?}_push_${SLUG:?}-${KEY:?}" \
      "/tmp/ci_watch2_task_${CLAUDE_CODE_SESSION_ID}_merge_${SLUG}-${KEY}"
```

## `/ci-watcher stop-all`

Stops every watcher THIS SESSION launched, and nothing else. It works only
through this session's own task-id files, so it can never reach into another
session's currently-owned watcher — not even one this session originally launched
and that a newer session has since superseded.

```bash
# Guard: without a session id the glob would match every session's files.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot enumerate ci watchers." >&2
    exit 1
fi
# An unmatched glob stays literal in bash, so the -f guard is what drops it.
for f in "/tmp/ci_watch2_task_${CLAUDE_CODE_SESSION_ID}"_*; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "${f##*/}" "$(cat "$f")"
done
```

For EACH line, call `TaskStop` on that task id, one by one. A task that already
finished on its own is inert — `TaskStop` on it is a harmless no-op, and a "task
not found" / "already finished" error is EXPECTED: ignore it, never treat it as a
failure. Then delete that file:

```bash
rm -f "/tmp/<the task file name from the listing above>"
```

Report one summary line per file. Exit without launching.

**Accepted limitation:** stale task-id files are never garbage-collected in the
background. They are only cleaned up opportunistically — when `/ci-watcher` runs
again in this session (a launch overwrites that key's file, `stop`/`stop-all`
deletes them). A very long-lived session can accumulate a few inert files in
`/tmp`; that is known and accepted, not an oversight.

# step 1: parse the arguments

## user input
"$ARGUMENTS"

## parse
- `stop` / `stop-all` → step 0 above.
- First word `merge` → merge mode; the branch is the SECOND word, if given.
- Otherwise → push mode; the branch is the first word, if given.
- No branch given → the current branch:
```bash
git branch --show-current
```

# step 2: launch the watcher

Use this for a push-mode launch (`/ci-watcher [branch]`) and for a merge-mode
launch (`/ci-watcher merge [branch]`) alike — only the mode word changes. Both
are FALLBACKS: normally the hook has already launched the watcher. Launch
manually when the hook did not fire (a command outside its trigger contract), or
when the user wants a forced relaunch, or — for merge mode — when the PR was
merged outside this session and no `gh pr merge` ever ran here.

Run the KEY block first. You do NOT need to check for an existing watcher: the
script's own lock evicts a stale one of the same kind automatically.

Then make a single **Bash** tool call:

- `command` (template — `<DIR>`, `<MODE>` and `<BRANCH>` are placeholders you
  replace with the literal values, NOT shell variables):

  `cd '<DIR>' && bash ~/.claude/skills/ci-watcher/ci_watch_once.sh <MODE> '<BRANCH>'`

- `run_in_background`: `true`
- NO explicit `timeout` override — this watcher ends only on a real CI result,
  not on a time box.

Fully substituted example — this is the shape the tool call must have:

```
cd '/Users/me/code/myrepo' && bash ~/.claude/skills/ci-watcher/ci_watch_once.sh push 'feat/my-branch'
```

Never pass the template through verbatim. A shell expands an unset `$DIR` to the
empty string, `cd ''` **succeeds silently**, and the watcher then starts in an
arbitrary directory, fails to resolve `owner/repo`, and exits 1.

Why the command looks like that:

- **cwd is inlined as a literal, not inherited.** `ci_watch_once.sh` shells out
  to `gh repo view`, which resolves its repo from the process cwd. That cannot be
  left to chance.
- **Every interpolated value is SINGLE-quoted.** This is the security-relevant
  bullet. Git branch names may legally contain `$`, backticks, `;` and `&`, and
  the command string is executed by a shell. Double quotes stop word splitting,
  globbing, `;` and `&` — they do **not** stop `$VAR`, `` `cmd` `` or `$(cmd)`,
  so a branch named ``x`touch /tmp/pwn` `` or `x$(id)` would execute inside
  double quotes. Only single quotes suppress every form of substitution. If a
  value itself contains a single quote, close, escape, reopen: write `'` as
  `'\''` (so `it's` becomes `'it'\''s'`).
- **`run_in_background: true`, and the Bash tool only.** The watcher ends on a
  real end state, which may be minutes or hours away. A background Bash task is
  not subject to the foreground tool timeout; its stdout arrives as one
  completion notification.
- **stdout is the notification.** `ci_watch_once.sh` prints its result lines on
  stdout and every diagnostic to `/tmp/ci_watch2_<kind>_<slug>-<KEY>.log`. Do not
  redirect stream 1 — that would swallow the result and the watcher would go
  silent with no error.

Immediately after the Bash call returns its `task_id`, write it verbatim to this
session's task-id file, atomically, so `/ci-watcher stop-all` can find it later.
The script can never know its own `task_id` — that value exists only here, in
your turn — so persisting it is YOUR job, not the script's:

```bash
# Temp file, then rename — rename is atomic on the same filesystem. The temp
# name is per-invocation unique (mktemp), NOT a fixed ".tmp" suffix: two
# near-simultaneous launches would otherwise write and rename the very same temp
# path and one could publish the other's half-written id. The temp name must also
# NOT start with "ci_watch2_task_": stop-all globs
# "/tmp/ci_watch2_task_<SESSION>_*", and a temp file caught by that glob would be
# enumerated as a phantom watcher.
TASK_FILE="/tmp/ci_watch2_task_${CLAUDE_CODE_SESSION_ID:?}_${MODE:?}_${SLUG:?run the KEY block first}-${KEY:?}"
TASK_TMP=$(mktemp "/tmp/.ci_watch2_tmp_task.XXXXXX")
printf '%s' "<TASK_ID>" > "$TASK_TMP" && mv "$TASK_TMP" "$TASK_FILE"
```

This is the same instruction the hook injects, word for word in substance, so a
human-invoked `/ci-watcher` and a hook-triggered one behave identically.

Finally, tell the user one line: `CI watcher running for <branch> (<mode> mode,
log: /tmp/ci_watch2_<kind>_<slug>-<KEY>.log)`. The watcher's own result arrives
later, on its own, as the background task's completion notification.

If the watcher fails immediately, its stdout says so in one line (a persistent
`gh` error, or a lock it could not acquire). Show the user that line and the tail
of the log:

```bash
tail -n 20 "/tmp/ci_watch2_${MODE:?}_${SLUG:?run the KEY block first}-${KEY:?}.log"
```

# behavior notes

## keep fixing what the watcher reports

A `CI FAILED` report is a job to do, not an alert to escalate. Fix the cause and
push again — the hook launches a fresh push watcher on that push automatically.
Do NOT ignore a failure report and do NOT hand it back to the user unfixed.

## a post-merge failure gets its own PR

If merge-mode reports `Post-merge CI FAILED`, fix it in a separate, NEW PR. Never
reopen or reuse the merged one.
