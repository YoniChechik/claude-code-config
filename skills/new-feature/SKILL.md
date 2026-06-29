---
name: "new-feature"
description: "Start new feature with full planning"
argument-hint: "[feature-description]"
---

Creates a new feature branch using a git worktree for isolated development with full planning.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

## Process

### Step 1: Create Worktree
Run `/create-worktree $ARGUMENTS`.

### Step 2: Run Feature workflow
Read the file `~/.claude/feature-workflow.md` and work according to workflow.
