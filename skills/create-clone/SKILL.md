---
name: "create-clone"
description: "Create isolated git clone for feature"
argument-hint: "[feature-description]"
---

Creates a git clone for isolated feature development. Handles both new features and existing remote branches.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description."

## Process

### Step 1: Parse Feature Description
- Decide on feature name based on description
- Convert feature name to kebab-case for branch naming
- Feature name must NOT contain `/`. If the chosen name has a prefix like `feat/`, `fix/`, `chore/`, etc., strip everything up to and including the last `/` (e.g. `feat/add-login` → `add-login`). The final name must be a flat kebab-case string with no slashes.

### Step 2: Run the clone script
```bash
bash ~/.claude/skills/create-clone/create_clone.sh "$FEATURE_NAME"
```
This handles: fetching latest main from origin, branch detection, cloning, branching off `origin/main` (never a stale local main), env symlinking, and environment setup.

### Step 3: Notify User
Tell user:
- The clone has been created at `_clones/$FEATURE_NAME`
- The branch `$FEATURE_NAME` is tracking remote

### Step 4: Change to Feature Directory
Change to the feature clone directory using `/cd-permanent _clones/$FEATURE_NAME` skill.

## IMPORTANT First Action
Add all 4 steps to task list and start working on this skill's workflow.
