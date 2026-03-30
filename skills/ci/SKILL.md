---
name: "ci"
description: "Run the CI watcher script for the current or specified branch"
argument-hint: "[branch]"
---

CI watcher: Inform CI state from PR, report fail status (or keep silent if CI passes).
If fail- the watcher will inform the LLM what to fix. remember to relaunch immediately when exits on fail to catch next commit and validate the fix.


# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determin branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: run the CI watcher script in the background for the specified branch

Run this command in the background:
```
bash ~/.claude/scripts/ci_watch_persistent.sh <branch>
```

