---
name: "cd-permanent"
description: "Change directory permanently within the session (project tree only)"
---

## Instructions

### Step 1: Parse and Validate Path

Parse `$ARGUMENTS` as the target path.

If empty: Show usage: `/cd-permanent <path>`

### Step 2: Check if Path is Within Project

```bash
# Get project root and target real path
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TARGET_PATH=$(realpath -m "$ARGUMENTS" 2>/dev/null || echo "$ARGUMENTS")
```

Check if `$TARGET_PATH` starts with `$PROJECT_ROOT`:
- If YES: Continue to Step 3
- If NO: Continue to Step 4

### Step 3: Change Directory (Within Project)

```bash
cd "$TARGET_PATH"
pwd
```

Confirm: "Changed directory to: [new path]"

### Step 4: Explain Limitation (Outside Project)

Claude Code enforces staying within the project tree. The working directory resets when navigating outside.

**Why this happens:**
- Claude Code sandbox restricts directory changes to the project root and its subdirectories
- Symlinks that resolve outside the project are also blocked
- This is a security/isolation feature

**Alternatives:**
1. Run `/add-dir <path>` in the CLI to add an external directory
2. Add path to `additionalDirectories` in settings
3. Start a new session from that directory
4. Create a symlink inside the project that points to internal content

Do NOT attempt the cd - it will silently reset.
