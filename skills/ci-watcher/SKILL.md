---
name: "ci-watcher"
description: "Run the CI watcher script for the current or specified branch. One watcher per branch, several at once per session. Use `/ci-watcher stop` for the current branch, `/ci-watcher stop <branch>` for another, `/ci-watcher stop-all` for every watcher of this session."
argument-hint: "[branch|stop [branch]|stop-all]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass through the `Monitor` tool's stdout event stream.
Claude must never stop the watcher on its own initiative. The watcher itself may still exit on a terminal condition (PR closed without merge, no CI on the default branch, main-CI timeout, main CI resolved) — that is fine and is not a Claude-initiated kill.

One session can run SEVERAL watchers at once — one per branch. Every `/tmp`
file is keyed on a per-branch `SLOT`, so launching a watcher for `feat/b` never
disturbs the one already watching `feat/a`.

**Tool availability:** `Monitor` and `TaskStop` are deferred tools in this harness. If they are not already available, load them first with `ToolSearch` query `select:Monitor,TaskStop`.

# **CRITICAL RULE: DO NOT KILL THE CI WATCHER AUTOMATICALLY**

**THE CI WATCHER MUST NEVER BE KILLED BY CLAUDE ON ITS OWN.** This is an absolute rule with no exceptions:

- **DO NOT** kill the watcher when CI passes.
- **DO NOT** kill the watcher when CI fails.
- **DO NOT** kill the watcher when a PR is merged.
- **DO NOT** kill the watcher on merge to `main`.
- **DO NOT** kill the watcher when the feature looks "done".
- **DO NOT** kill the watcher on any other "natural completion" event.
- **DO NOT** call `/ci-watcher stop`, `TaskStop` on the watcher's task id, `kill <pid>`, `pkill ci_watch`, or any equivalent on your own initiative.

**THE ONLY WAY TO STOP THE WATCHER IS AN EXPLICIT USER REQUEST**, such as the user typing `/ci-watcher stop` or giving a clear natural-language instruction like "stop the ci watcher" / "kill the ci watcher". If the user has not explicitly asked, leave it running.

# the SLOT: how every `/tmp` file is keyed

- `SESSION` = `$CLAUDE_CODE_SESSION_ID` (the full UUID).
- `IDENTITY` = `"<owner>/<repo>#<branch>"`, raw and unsanitized.
- `IDENTITY_HASH` = the first 10 hex chars of `sha256(IDENTITY)`.
- `BRANCH_SLUG` = `"<readable branch prefix>-<IDENTITY_HASH>"`.
- `SLOT` = `"${SESSION}_${BRANCH_SLUG}"`, and the files are
  `/tmp/ci_watch_state_<SLOT>`, `/tmp/ci_watch_lock_<SLOT>`,
  `/tmp/ci_watch_pr_<SLOT>`, `/tmp/ci_watch_task_<SLOT>` and
  `/tmp/ci_watch_<SLOT>.log`.

The hash, not the readable prefix, is what makes the slot unique. `owner/repo`
is folded in because a branch name alone is not a watcher identity: one session
can `cd` between worktrees of two repos that both have a branch called `main`.

One more file is SESSION-level, with no branch component:
`/tmp/ci_watch_finished_<SESSION>` collects every PR that merged AND went green
on post-merge CI. `ci_watch.py` appends to it; `status_line.sh` renders it. No
path in this skill writes or deletes it.

Run this block FIRST in every flow below — launch, `stop`, and `stop <branch>`.
Run it from the repo directory whose branch you are targeting:

```bash
# Guard: without a session id every path collapses to /tmp/ci_watch_*_ and one
# session would read (or stop) another session's watcher.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot key the ci watcher files." >&2
    exit 1
fi
# BRANCH: preset it for `stop <branch>`; otherwise the current branch is used.
# Inline a user-supplied branch as a SINGLE-quoted literal (BRANCH='feat/x'),
# never through double quotes — see the quoting rule in step 2.
BRANCH="${BRANCH:-$(git branch --show-current)}"
if [[ -z "$BRANCH" ]]; then
    echo "Error: no branch resolved; cannot key the ci watcher files." >&2
    exit 1
fi
# owner/repo is part of the identity, so two worktrees of different repos that
# share a branch name still get two distinct slots.
IDENTITY="$(gh repo view --json nameWithOwner -q .nameWithOwner)#${BRANCH}"
# The hash — not the readable prefix below — is what guarantees uniqueness.
IDENTITY_HASH=$(printf '%s' "$IDENTITY" | shasum -a 256 | cut -c1-10)
# Readable prefix: every BYTE outside [A-Za-z0-9._-] becomes _, capped at 40.
# LC_ALL=C keeps tr and cut in byte mode, so this matches ci_watch.py's
# sanitize_branch() exactly even for a non-ASCII branch name.
BRANCH_SLUG="$(printf '%s' "$BRANCH" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-40)-${IDENTITY_HASH}"
SLOT="${CLAUDE_CODE_SESSION_ID}_${BRANCH_SLUG}"
echo "SESSION=${CLAUDE_CODE_SESSION_ID}"
echo "DIR=$(pwd)"
echo "SLOT=${SLOT}"
# Monitor task id for THIS slot only, or NONE. Other branches' watchers in the
# same session are never read and never touched here.
cat "/tmp/ci_watch_task_${SLOT}" 2>/dev/null || echo NONE
```

# stale task-id handling

`/tmp/ci_watch_task_<SLOT>` holds the `Monitor` task id of ONE branch's watcher.
The stored id can point at a task whose underlying process already exited on its
own (terminal condition) or crashed. Never trust the file's contents without a
liveness check first.

The liveness check is the PID lockfile — the same signal `status_line.sh` and
`_notify.sh` use. Prepend the slot from the block above as a single-quoted
literal, e.g. `SLOT='4f1c2b90-…_feat_my-branch-9a1b2c3d4e' bash -c '…'`:
```bash
# Guard: the lockfile is keyed on the full SLOT. Without it the path collapses
# to /tmp/ci_watch_lock_ and the check reports another watcher's state.
if [[ -z "${SLOT:-}" ]]; then
    echo "Error: SLOT is unset; run the slot block first." >&2
    exit 1
fi
# Read the PID the watcher wrote into its lockfile, then confirm that PID is
# still a live ci_watch process (ps args must contain "ci_watch"). Prints
# ALIVE, MUTE (alive, but its notifications reach nobody) or DEAD.
LOCK="/tmp/ci_watch_lock_${SLOT}"
STATE="/tmp/ci_watch_state_${SLOT}"
PID=$(cat "$LOCK" 2>/dev/null || echo "")
if [[ -n "$PID" ]] && ps -p "$PID" -o args= 2>/dev/null | grep -q ci_watch; then
    if grep -q ':monitor-detached@' "$STATE" 2>/dev/null; then
        echo "MUTE $PID"
    else
        echo "ALIVE $PID"
    fi
else
    echo "DEAD"
fi
```

Then:
- **DEAD** — the stored task id is stale. Call `TaskStop` on it anyway (best
  effort). A "task not found" / "already finished" error is EXPECTED here: ignore
  it, do NOT treat it as a launch failure. Then delete the task-id file.
- **MUTE `<PID>`** — the process runs but its stdout writes fail, so no CI
  result will ever reach you again. Treat it exactly like **ALIVE** here, then
  relaunch it (step 2) and tell the user why; a relaunch is not a Claude-
  initiated kill.
- **ALIVE** — call `TaskStop` on the id for real, then confirm both the Monitor
  task reports stopped AND the PID from the lockfile is gone: re-run the check
  above at 1s intervals, **at most 10 times**. The loop is bounded on purpose —
  an unbounded wait would wedge `/ci-watcher stop` and every relaunch forever.
  - It prints `DEAD` within 10 tries — delete the task-id file and continue.
  - It still prints `ALIVE <PID>` after 10 tries — `TaskStop` did not kill the
    real process. Do NOT loop again and do NOT launch a second watcher. Report
    to the user that the watcher survived `TaskStop`, give them the PID, and
    stop. Killing it is an explicit user decision (see the CRITICAL RULE).

This handling is always scoped to ONE slot. Applying it to `feat/a`'s watcher
never reads, stops, or deletes anything belonging to `feat/b`'s watcher.

# step 0: handle `stop` and `stop-all`

## `/ci-watcher stop` and `/ci-watcher stop <branch>`

Both stop exactly ONE watcher and exit — do NOT launch anything.

- No further argument: the CURRENT branch's watcher. Run the slot block with no
  `BRANCH` preset.
- `stop <branch>`: that branch's watcher. Run the slot block with
  `BRANCH='<branch>'` preset as a single-quoted literal.

The slot block prints the stored task id (or `NONE`) on its last line.

If it is `NONE`, the task id is missing — but a watcher may still be running
(the `/tmp` file can be reaped, or the session can have crashed between
`Monitor` returning and the id being persisted). Do NOT report "nothing to stop"
yet. Run the liveness check above first:
- **DEAD** — there really is nothing to stop for that branch. Report that and exit.
- **ALIVE `<PID>`** — a watcher is running with no recoverable task id. Kill it
  by PID instead, then confirm with the same bounded re-check (1s intervals, at
  most 10 tries):
```bash
# PID is the number from the ALIVE line above. `:?` fails loud rather than
# running `kill ""` if this block is ever run on its own.
kill "${PID:?run the liveness check first and pass its PID}"
```
  If it still reports `ALIVE` after 10 tries, report the surviving PID to the
  user and stop; do not escalate to `kill -9` on your own initiative.

Otherwise (the last line is a task id) apply the stale-task-id handling above
for that slot, then remove that slot's file:
```bash
rm -f "/tmp/ci_watch_task_${SLOT:?run the slot block first}"
```
Exit without launching.

## `/ci-watcher stop-all`

Stops EVERY watcher of this session. Enumerate the slots first — the union of
the task-id, lock and state files, so a watcher whose task-id file was reaped
(or was never written, because the session died before `Monitor` returned) is
still found through its lock or state file:
```bash
# Guard: without a session id the glob would match every session's files.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot enumerate ci watchers." >&2
    exit 1
fi
# Three independent discovery sources, de-duplicated. `sort -u` collapses a slot
# that shows up in more than one of them.
for kind in task lock state; do
    for f in "/tmp/ci_watch_${kind}_${CLAUDE_CODE_SESSION_ID}"_*; do
        # An unmatched glob stays literal in bash, so skip anything that is not
        # a real file rather than echoing the pattern as a slot.
        [ -e "$f" ] || continue
        printf '%s\n' "${f##*/ci_watch_${kind}_}"
    done
done | sort -u
```
Then, for EACH slot printed, apply the stale-task-id handling above with that
`SLOT` (liveness check, `TaskStop` on the stored id if there is one, otherwise
`kill "$PID"`, confirm gone, `rm -f` the task-id file). Report one summary line
per slot: stopped / already dead / survived. Exit without launching.

# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determine branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: launch the CI watcher

Run the slot block first (top of this file). It prints `SESSION`, `DIR`, `SLOT`
and the existing task id for this branch's slot.

Take the branch name from step 1 (the output of `git branch --show-current`, or
the user's argument). Never re-echo it through another double-quoted shell
string — see the quoting rule below.

If the task id is not `NONE`, apply the stale-task-id handling above BEFORE
launching. It targets ONLY this branch's slot: relaunching for `feat/b` never
evicts the watcher that is already running for `feat/a`.

Then make a single `Monitor` call:

- `command` (template — `<DIR>`, `<SESSION>`, `<BRANCH>` and `<SLOT>` are
  placeholders you replace with the literal values, NOT shell variables):

  `cd '<DIR>' && exec env CLAUDE_CODE_SESSION_ID='<SESSION>' uv run ~/.claude/skills/ci-watcher/ci_watch.py '<BRANCH>' 2>>'/tmp/ci_watch_<SLOT>.log'`

- `description`: `CI status for branch <BRANCH>`
- `persistent`: `true`
- `timeout_ms`: `3600000` (required by the schema; ignored when `persistent` is true)

Fully substituted example — this is the shape the tool call must have:

```
cd '/Users/me/code/myrepo' && exec env CLAUDE_CODE_SESSION_ID='4f1c2b90-1c3d-4a55-9e21-7b6a0d5e8c11' uv run ~/.claude/skills/ci-watcher/ci_watch.py 'feat/my-branch' 2>>'/tmp/ci_watch_4f1c2b90-1c3d-4a55-9e21-7b6a0d5e8c11_feat_my-branch-9a1b2c3d4e.log'
```

Never pass the template through verbatim. A shell expands an unset `$DIR` to the
empty string, `cd ''` **succeeds silently**, and the watcher then starts in an
arbitrary directory with an empty session id and exits 2 — to stderr, so you
would never see it.

Why the command looks like that:

- **cwd and session id are inlined as literals, not inherited.** `Monitor` runs
  in the same shell environment as Bash, but neither its cwd nor its env
  inheritance is contractually guaranteed. `ci_watch.py` exits 2 without
  `CLAUDE_CODE_SESSION_ID`, and it shells out to `gh repo view` and
  `git ls-remote`, which need the repo directory. Neither can be left to chance.
  `ci_watch.py` derives the same `SLOT` itself from the session id, the branch
  and its own `gh repo view` call, so the slot is never passed as an argument —
  only the log path spells it out.
- **Every interpolated value is SINGLE-quoted.** This is the security-relevant
  bullet. Git branch names may legally contain `$`, backticks, `;` and `&`, and
  the command string is executed by a shell. Double quotes stop word splitting,
  globbing, `;` and `&` — they do **not** stop `$VAR`, `` `cmd` `` or `$(cmd)`,
  so a branch named ``x`touch /tmp/pwn` `` or `x$(id)` would execute inside
  double quotes. Only single quotes suppress every form of substitution.
  If a value itself contains a single quote, close, escape, reopen: write `'`
  as `'\''` (so `it's` becomes `'it'\''s'`). The log-redirect target is
  single-quoted for the same reason, even though the slot holds only a UUID,
  a sanitized branch slug and a hex hash.
- **`exec` replaces the shell.** Without it, `Monitor` would track a parent shell
  whose child is the real `uv`/python process, and `TaskStop` could kill the
  parent while orphaning the watcher. With `exec`, the tracked process IS the
  watcher.
- **stderr goes to the log file.** stdout is the Monitor event stream: one line
  = one session notification. `ci_watch.py` writes every diagnostic to stderr,
  which is appended to `/tmp/ci_watch_<SLOT>.log` so `tail -f` debugging still
  works. The cost is that stderr no longer shows up in `TaskOutput`. Redirect
  stream 2 ONLY. An all-streams redirect, or any redirect of stream 1, would
  swallow every notification and the watcher would go silent with no error.

Then persist the returned task id atomically so a concurrent reader never
sees a half-written id:
```bash
# Temp file, then rename — rename is atomic on the same filesystem. The temp
# name is per-invocation unique (mktemp), NOT a fixed ".tmp" suffix: two
# near-simultaneous launches for the same slot would otherwise write and rename
# the very same temp path and one could publish the other's half-written id.
TASK_FILE="/tmp/ci_watch_task_${SLOT:?run the slot block first}"
TASK_TMP=$(mktemp "${TASK_FILE}.XXXXXX")
printf '%s' "<TASK_ID>" > "$TASK_TMP" && mv "$TASK_TMP" "$TASK_FILE"
```

Persist the id BEFORE verifying the launch, never after: a watcher that is alive
but slow to appear must still be stoppable, and an id pointing at a dead task is
handled by the stale-task-id logic above.

Finally, confirm the watcher actually came up. `ci_watch.py` can die within a
second (branch not on the remote, missing `gh` auth, `uv` resolution failure),
and all of those messages go to the log file, not to `TaskOutput` — so without
this check a dead-on-arrival watcher is completely silent. Run the liveness
check above at 1s intervals, at most 10 times (`uv` may need a moment to start):
- **ALIVE `<PID>`** — report to the user: `CI watcher running for branch
  <BRANCH> (PID <PID>, log: /tmp/ci_watch_<SLOT>.log)`.
- Still **DEAD** after 10 tries — the watcher failed to start. Show the user the
  tail of the log and stop:
```bash
tail -n 20 "/tmp/ci_watch_${SLOT:?run the slot block first}.log"
```

Note: state, PR-cache, lock, log and task-id files in `/tmp/` are all keyed on
the per-branch `SLOT`, so a session can hold several watchers at once and each
one's files are disjoint. The watched branch is also recorded inside the state
file as `<branch>:<state>`. To watch an ADDITIONAL branch, just run step 2 again
for it — nothing has to be stopped first. To replace one branch's watcher, run
step 2 for that same branch; its own stale-task-id handling evicts only it.

# behavior notes

## repeated sync is BY DESIGN

The watcher will frequently surface "CI behind" / "branch behind" problems, and that means
we will repeatedly need to sync. **This is intentional, not a bug.** Do NOT ignore any
"CI behind" / branch-behind alert, and do NOT escalate it to the user. Just keep fixing and
re-syncing every single time it comes up — however many times that is.

## keep watching after merge

After a PR is merged, **do NOT kill the watcher** (see the CRITICAL RULE above). It keeps
watching the CI run triggered by the merge to `main` and will alert us if that post-merge
run fails. If the post-merge `main` CI fails, fix it in a separate/new PR — never reopen or
reuse the merged one.

Once the post-merge CI goes green, `ci_watch.py` appends that PR to
`/tmp/ci_watch_finished_<SESSION>` and the status line moves it from its own
`PR #N | post merge: …` row into the shared `finished PRs: …` row, which grows
for the life of the session.
