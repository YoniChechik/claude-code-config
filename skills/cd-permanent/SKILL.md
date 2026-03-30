---
name: "cd-permanent"
description: "Change directory within the session"
argument-hint: "[path]"
---

## Instructions

### Step 1: Parse Input

Parse `$ARGUMENTS` as the target path.

If empty: exit with error and explain usage.


### Step 2: Change Directory

NOTE: this must run as 2 different bash tool calls
```bash
cd "$TARGET_PATH"
pwd
```

Confirm: "Changed directory to: [new path]"
or if error: "Error changing directory: [error message]- a known limitation is cd out of the base directory where the session started."
