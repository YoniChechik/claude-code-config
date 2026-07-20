---
name: "ci-watcher"
description: "Run the CI watcher for the current or specified branch (multiple branches can be watched at once). `/ci-watcher stop` kills ALL watchers for this session; `/ci-watcher stop <branch>` kills only that branch's watcher."
argument-hint: "[branch|stop [branch]]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass via webhook channel.
Launch once per feature — the watcher never exits, so no re-launch is needed.

# **CRITICAL RULE: DO NOT KILL THE CI WATCHER AUTOMATICALLY**

**THE CI WATCHER MUST NEVER BE KILLED BY CLAUDE ON ITS OWN.** This is an absolute rule with no exceptions:

- **DO NOT** kill the watcher when CI passes.
- **DO NOT** kill the watcher when CI fails.
- **DO NOT** kill the watcher when a PR is merged.
- **DO NOT** kill the watcher on merge to `main`.
- **DO NOT** kill the watcher when the feature looks "done".
- **DO NOT** kill the watcher on any other "natural completion" event.
- **DO NOT** call `/ci-watcher stop`, `touch /tmp/ci_watch_kill_*`, `kill <pid>`, `pkill ci_watch`, or any equivalent on your own initiative.

The watcher is intentionally always-on and stays alive across CI runs, PR merges, branch switches, and feature transitions.

**THE ONLY WAY TO STOP THE WATCHER IS AN EXPLICIT USER REQUEST**, such as the user typing `/ci-watcher stop` or giving a clear natural-language instruction like "stop the ci watcher" / "kill the ci watcher". If the user has not explicitly asked, leave it running.

# step 0: handle `stop` subcommand

If the first argument is `stop`, drop a per-branch kill flag and exit — do NOT launch the watcher. State/lock/kill files are keyed by a composite `<CLAUDE_CODE_SESSION_ID>__<sanitized_branch>`, where `sanitize()` MUST stay byte-identical to `ci_watch.py:sanitize_branch` (same readable transform + `sha256(branch)[:8]` suffix); divergence sends the kill flag to a filename the watcher never checks.

Two modes:

- `/ci-watcher stop <branch>` — stop only that branch:
```bash
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot stop ci watcher." >&2
    exit 1
fi
# MUST match ci_watch.py:sanitize_branch byte-for-byte.
sanitize() {
    local b="$1" readable hash8
    readable=$(printf '%s' "$b" | sed 's#[^A-Za-z0-9._-]#-#g')  # replace unsafe chars
    hash8=$(printf '%s' "$b" | shasum -a 256 | cut -c1-8)        # sha256(branch)[:8]
    printf '%s-%s' "$readable" "$hash8"
}
BRANCH="<branch arg>"
touch "/tmp/ci_watch_kill_${CLAUDE_CODE_SESSION_ID}__$(sanitize "$BRANCH")"
echo "CI watcher stop flag set for branch $BRANCH"
```

- bare `/ci-watcher stop` — fan out to EVERY live watcher for this session:
```bash
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot stop ci watcher." >&2
    exit 1
fi
# nullglob FIRST so an unmatched glob yields zero iterations, not a literal string.
shopt -s nullglob
count=0
# Enumerate live watchers by their lock files (written directly, no mkstemp temp
# ambiguity); the composite key is the filename after the ci_watch_lock_ prefix.
for lock in /tmp/ci_watch_lock_"${CLAUDE_CODE_SESSION_ID}"__*; do
    composite="${lock#/tmp/ci_watch_lock_}"
    touch "/tmp/ci_watch_kill_${composite}"
    count=$((count + 1))
done
shopt -u nullglob
if [ "$count" -eq 0 ]; then
    echo "No CI watchers running for session ${CLAUDE_CODE_SESSION_ID}"
else
    echo "CI watcher stop flag set for $count watcher(s) in session ${CLAUDE_CODE_SESSION_ID}"
fi
```

The running watcher(s) detect the flag at the next poll iteration and exit cleanly.

# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determine branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: get the webhook HTTP port

Call the `get_port` MCP tool (from the webhook server). It returns `PORT:TOKEN` format.
Parse the result: everything before the first `:` is `$PORT`, everything after is `$SESSION_TOKEN`.

# step 3: launch the CI watcher

The watcher sends notifications via curl to the webhook HTTP server on the port obtained above.

Launch with shell-level backgrounding (do NOT use run_in_background=true — the process dies when the subagent exits):
```bash
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot launch ci watcher." >&2
    exit 1
fi

# MUST match ci_watch.py:sanitize_branch byte-for-byte (readable + sha256[:8]).
sanitize() {
    local b="$1" readable hash8
    readable=$(printf '%s' "$b" | sed 's#[^A-Za-z0-9._-]#-#g')  # replace unsafe chars
    hash8=$(printf '%s' "$b" | shasum -a 256 | cut -c1-8)        # sha256(branch)[:8]
    printf '%s-%s' "$readable" "$hash8"
}
LOG="/tmp/ci_watch_${CLAUDE_CODE_SESSION_ID}__$(sanitize "$BRANCH").log"

uv run ~/.claude/scripts/ci_watch.py "$BRANCH" "$PORT" "$SESSION_TOKEN" \
    </dev/null >>"$LOG" 2>&1 &
echo "CI watcher launched for branch $BRANCH (PID $!, log: $LOG)"
```

Note: state, PR-cache, lock, kill, and log files in `/tmp/` are keyed by the
composite `ci_watch_<kind>_<CLAUDE_CODE_SESSION_ID>__<sanitized_branch>`, where
`sanitized_branch = <readable>-<sha256(branch)[:8]>`. The hash suffix guarantees
distinct branches never collide, so **several branches can be watched
concurrently in the same session** — each gets its own files and status-line row.
The watched branch is also recorded inside the state file as `<branch>:<state>:<epoch>`
(epoch = last state transition, drives the status-line timer). Re-launching the
SAME branch evicts its own prior watcher via the per-branch PID lock; other
branches are untouched.

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
