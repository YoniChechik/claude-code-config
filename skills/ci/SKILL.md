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

# step 2: resolve the webhook port and launch the CI watcher

The watcher runs shell-backgrounded (PPID=1), so it cannot find the Claude session via ancestry walk.
We must resolve the port NOW (while we still have valid Claude ancestry) and export it.

Launch with shell-level backgrounding (do NOT use run_in_background=true — the process dies when the subagent exits):
```bash
# Source the shared port-resolution helper and resolve the port while we
# still have valid Claude ancestry (backgrounded processes lose ancestry).
source ~/.claude/scripts/_webhook_port.sh
CLAUDE_WEBHOOK_PORT=$(find_claude_port) || { echo "ERROR: Could not resolve Claude webhook port. CI watcher NOT launched — notifications would silently fail." >&2; exit 1; }
export CLAUDE_WEBHOOK_PORT
echo "Resolved webhook port: $CLAUDE_WEBHOOK_PORT"

# Launch watcher with the port exported and logs going to a branch-keyed file
# so failures are visible instead of silently swallowed.
bash ~/.claude/scripts/ci_watch_persistent.sh "$BRANCH" </dev/null >>/tmp/ci_watch_${BRANCH}.log 2>&1 &
echo "CI watcher launched for branch $BRANCH (PID $!, log: /tmp/ci_watch_${BRANCH}.log)"
```
