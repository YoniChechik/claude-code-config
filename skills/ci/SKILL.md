---
name: "ci"
description: "Run the CI watcher script for the current or specified branch"
argument-hint: "[branch]"
---

Run the CI watcher script in the background for the current or specified branch.

If $ARGUMENTS is provided, use it as the branch name. Otherwise, determine the current branch by running `git branch --show-current`.

Run this command in the background:
```
bash ~/.claude/scripts/ci_watch_persistent.sh <branch>
```

Inform the user that the CI watcher is running for the branch and will report pass/fail status.
