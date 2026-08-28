---
name: "ci-watcher"
description: "Run the CI watcher script for the current or specified branch. Use `/ci-watcher stop` to kill the watcher for the current session."
argument-hint: "[branch|stop]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass through the `Monitor` tool's stdout event stream.
Claude must never stop the watcher on its own initiative. The watcher itself may still exit on a terminal condition (PR closed without merge, no CI on the default branch, main-CI timeout, main CI resolved) — that is fine and is not a Claude-initiated kill.

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

# stale task-id handling

`/tmp/ci_watch_task_<slot>` holds the `Monitor` task id of the watcher for this
session. The stored id can point at a task whose underlying process already
exited on its own (terminal condition) or crashed. Never trust the file's
contents without a liveness check first.

The liveness check is the PID lockfile — the same signal `status_line.sh` and
`_notify.sh` use:
```bash
# Guard: the lockfile is keyed on the full session UUID. Without it the path
# collapses to /tmp/ci_watch_lock_ and reports another session's state.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot check ci watcher liveness." >&2
    exit 1
fi
# Read the PID the watcher wrote into its lockfile, then confirm that PID is
# still a live ci_watch process (ps args must contain "ci_watch"). Prints
# ALIVE or DEAD.
LOCK="/tmp/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}"
PID=$(cat "$LOCK" 2>/dev/null || echo "")
if [[ -n "$PID" ]] && ps -p "$PID" -o args= 2>/dev/null | grep -q ci_watch; then
    echo "ALIVE $PID"
else
    echo "DEAD"
fi
```

Then:
- **DEAD** — the stored task id is stale. Call `TaskStop` on it anyway (best
  effort). A "task not found" / "already finished" error is EXPECTED here: ignore
  it, do NOT treat it as a launch failure. Then delete the task-id file.
- **ALIVE** — call `TaskStop` on the id for real, then confirm both the Monitor
  task reports stopped AND the PID from the lockfile is gone: re-run the check
  above at 1s intervals, **at most 10 times**. The loop is bounded on purpose —
  an unbounded wait would wedge `/ci-watcher stop` and every relaunch forever.
  - It prints `DEAD` within 10 tries — delete the task-id file and continue.
  - It still prints `ALIVE <PID>` after 10 tries — `TaskStop` did not kill the
    real process. Do NOT loop again and do NOT launch a second watcher. Report
    to the user that the watcher survived `TaskStop`, give them the PID, and
    stop. Killing it is an explicit user decision (see the CRITICAL RULE).

# step 0: handle `stop` subcommand

If the first argument is `stop`, stop the watcher and exit — do NOT launch it:
```bash
# Guard: every /tmp file is keyed on the full session UUID.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot stop ci watcher." >&2
    exit 1
fi
# Read the stored Monitor task id; NONE means no watcher was ever launched here.
cat "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}" 2>/dev/null || echo NONE
```
If the output is `NONE`, the task id is missing — but a watcher may still be
running (the `/tmp` file can be reaped, or the session can have crashed between
`Monitor` returning and the id being persisted). Do NOT report "nothing to stop"
yet. Run the liveness check above first:
- **DEAD** — there really is nothing to stop. Report that and exit.
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

Otherwise (the output is a task id) apply the stale-task-id handling above
(liveness check, `TaskStop`, confirm gone), then remove the file:
```bash
rm -f "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}"
```
Exit without launching.

# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determine branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: launch the CI watcher

First, collect the values that must be inlined into the `Monitor` command, and
read any existing task id:
```bash
# Guard: ci_watch.py exits 2 without a session id, so fail loud here instead.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot launch ci watcher." >&2
    exit 1
fi
# SESSION and DIR get inlined as literals into the Monitor command below.
# The branch is deliberately NOT echoed here: it can be attacker-influenced text
# and this is a double-quoted shell string, where $(...) and backticks execute.
echo "SESSION=${CLAUDE_CODE_SESSION_ID} DIR=$(pwd)"
# Existing task id from a previous launch in this session, or NONE.
cat "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}" 2>/dev/null || echo NONE
```

Take the branch name from step 1 (the output of `git branch --show-current`, or
the user's argument). Never re-echo it through another double-quoted shell
string — see the quoting rule below.

If the task id is not `NONE`, apply the stale-task-id handling above (liveness
check, `TaskStop`, confirm gone) BEFORE launching. This covers both a plain
relaunch and a branch switch.

Then make a single `Monitor` call:

- `command` (template — `<DIR>`, `<SESSION>` and `<BRANCH>` are placeholders you
  replace with the literal values, NOT shell variables):

  `cd '<DIR>' && exec env CLAUDE_CODE_SESSION_ID='<SESSION>' uv run ~/.claude/skills/ci-watcher/ci_watch.py '<BRANCH>' 2>>'/tmp/ci_watch_<SESSION>.log'`

- `description`: `CI status for branch <BRANCH>`
- `persistent`: `true`
- `timeout_ms`: `3600000` (required by the schema; ignored when `persistent` is true)

Fully substituted example — this is the shape the tool call must have:

```
cd '/Users/me/code/myrepo' && exec env CLAUDE_CODE_SESSION_ID='4f1c2b90-1c3d-4a55-9e21-7b6a0d5e8c11' uv run ~/.claude/skills/ci-watcher/ci_watch.py 'feat/my-branch' 2>>'/tmp/ci_watch_4f1c2b90-1c3d-4a55-9e21-7b6a0d5e8c11.log'
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
- **Every interpolated value is SINGLE-quoted.** This is the security-relevant
  bullet. Git branch names may legally contain `$`, backticks, `;` and `&`, and
  the command string is executed by a shell. Double quotes stop word splitting,
  globbing, `;` and `&` — they do **not** stop `$VAR`, `` `cmd` `` or `$(cmd)`,
  so a branch named ``x`touch /tmp/pwn` `` or `x$(id)` would execute inside
  double quotes. Only single quotes suppress every form of substitution.
  If a value itself contains a single quote, close, escape, reopen: write `'`
  as `'\''` (so `it's` becomes `'it'\''s'`). The log-redirect target is
  single-quoted for the same reason, even though it only holds a UUID.
- **`exec` replaces the shell.** Without it, `Monitor` would track a parent shell
  whose child is the real `uv`/python process, and `TaskStop` could kill the
  parent while orphaning the watcher. With `exec`, the tracked process IS the
  watcher.
- **stderr goes to the log file.** stdout is the Monitor event stream: one line
  = one session notification. `ci_watch.py` writes every diagnostic to stderr,
  which is appended to `/tmp/ci_watch_<slot>.log` so `tail -f` debugging still
  works. The cost is that stderr no longer shows up in `TaskOutput`. Redirect
  stream 2 ONLY. An all-streams redirect, or any redirect of stream 1, would
  swallow every notification and the watcher would go silent with no error.

Then persist the returned task id atomically so a concurrent reader never
sees a half-written id:
```bash
# Write to a temp file, then rename — rename is atomic on the same filesystem.
printf '%s' "<TASK_ID>" > "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}.tmp" \
    && mv "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}.tmp" \
          "/tmp/ci_watch_task_${CLAUDE_CODE_SESSION_ID}"
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
  <BRANCH> (PID <PID>, log: /tmp/ci_watch_<slot>.log)`.
- Still **DEAD** after 10 tries — the watcher failed to start. Show the user the
  tail of the log and stop:
```bash
tail -n 20 "/tmp/ci_watch_${CLAUDE_CODE_SESSION_ID}.log"
```

Note: state, PR-cache, lock, log, and task-id (`/tmp/ci_watch_task_<slot>`) files
in `/tmp/` are all keyed on `CLAUDE_CODE_SESSION_ID` (full UUID). The watched
branch is recorded inside the state file as `<branch>:<state>`. To switch
branches mid-feature: read the old task id from `/tmp/ci_watch_task_<slot>`,
apply the stale-task-id handling above, launch a new `Monitor` with the new
branch, then atomically overwrite the task-id file with the new id.

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
