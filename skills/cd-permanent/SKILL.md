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

```bash
cd TARGET_PATH
```

Make sure to not prepend or append any other commands- this MUST be the only command running in Bash tool.

# step 3: Confirm Change
```bash
pwd
```

Confirm: "Changed directory to: [new path]"
or if error: "Error changing directory: [error message]- a known limitation is cd out of the base directory where the session started."
