---
name: "ci"
description: "Run the CI watcher script for the current or specified branch"
argument-hint: "[branch]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass via webhook channel.
Launch once per feature — the watcher never exits, so no re-launch is needed.

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
`/ci`, which kills the old watcher via its PID lock and starts a new one with
the new branch.
