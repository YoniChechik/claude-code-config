---
name: "create-worktree"
description: "Create isolated git worktree for feature"
argument-hint: "[feature-description]"
---

Creates a git worktree for isolated feature development. Handles new features, existing local branches, and existing remote branches.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description."

## Process

### Step 1: Parse Feature Description
- Decide on feature name based on description
- Convert feature name to kebab-case for branch naming
- Feature name must NOT contain `/`. If the chosen name has a prefix like `feat/`, `fix/`, `chore/`, etc., strip everything up to and including the last `/` (e.g. `feat/add-login` → `add-login`). The final name must be a flat kebab-case string with no slashes.

### Step 2: Run the worktree script
```bash
bash ~/.claude/skills/create-worktree/create_worktree.sh "$FEATURE_NAME"
```
This handles: fetching latest main from origin, branch detection (new / existing local / existing remote), `git worktree add` at `.claude/worktrees/$FEATURE_NAME`, branching off `origin/main` (never a stale local main), env symlinking, environment setup, and setting the terminal tab title to `$FEATURE_NAME` via an OSC escape sequence.

The script prints the worktree path (relative to the repo root) as its last stdout line.

### Step 3: Notify User
Tell user:
- The worktree has been created at `.claude/worktrees/$FEATURE_NAME`
- The branch `$FEATURE_NAME` is tracking remote
- The tab title is set to `$FEATURE_NAME` automatically. To also rename the session in the resume picker, they may optionally type `/rename $FEATURE_NAME` themselves — this requires the manual command because `/rename` is interactive-only and cannot be automated.

### Step 4: Change to Feature Directory
Change to the feature worktree directory using `/cd-permanent .claude/worktrees/$FEATURE_NAME` skill.
