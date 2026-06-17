---
name: "ci-watcher"
description: "Run the CI watcher script for the current or specified branch. Use `/ci-watcher stop` to kill the watcher for the current session."
argument-hint: "[branch|stop]"
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

If the first argument is `stop`, drop a per-session kill flag and exit — do NOT launch the watcher:
```bash
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot stop ci watcher." >&2
    exit 1
fi
touch "/tmp/ci_watch_kill_${CLAUDE_CODE_SESSION_ID}"
echo "CI watcher stop flag set for session ${CLAUDE_CODE_SESSION_ID}"
```
The running watcher (if any) will detect the flag at its next poll iteration and exit cleanly.

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

uv run ~/.claude/scripts/ci_watch.py "$BRANCH" "$PORT" "$SESSION_TOKEN" \
    </dev/null >>/tmp/ci_watch_${CLAUDE_CODE_SESSION_ID}.log 2>&1 &
echo "CI watcher launched for branch $BRANCH (PID $!, log: /tmp/ci_watch_${CLAUDE_CODE_SESSION_ID}.log)"
```

Note: state, PR-cache, lock, and log files in `/tmp/` are all keyed on
`CLAUDE_CODE_SESSION_ID` (full UUID). The watched branch is recorded inside
the state file as `<branch>:<state>`. Switching branches mid-feature re-launches
`/ci-watcher`, which kills the old watcher via its PID lock and starts a new one with
the new branch.

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
