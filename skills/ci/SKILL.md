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

# step 2: run the CI watcher script in the background for the specified branch

Launch with shell-level backgrounding (do NOT use run_in_background=true — the process dies when the subagent exits):
```bash
bash ~/.claude/scripts/ci_watch_persistent.sh <branch> </dev/null >/dev/null 2>&1 &
```
