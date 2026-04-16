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

Call the `get_port` MCP tool (from the webhook server) to obtain the HTTP port for this session.
Store the result in a variable `$PORT`.

# step 3: launch the CI watcher

The watcher sends notifications via curl to the webhook HTTP server on the port obtained above.

Launch with shell-level backgrounding (do NOT use run_in_background=true — the process dies when the subagent exits):
```bash
# Launch watcher with logs going to a branch-keyed file
# so failures are visible instead of silently swallowed.
bash ~/.claude/scripts/ci_watch_persistent.sh "$PORT" "$BRANCH" </dev/null >>/tmp/ci_watch_${BRANCH}.log 2>&1 &
echo "CI watcher launched for branch $BRANCH (PID $!, log: /tmp/ci_watch_${BRANCH}.log)"
```
