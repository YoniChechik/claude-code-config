---
name: "new-feature"
description: "Start new feature with full planning"
argument-hint: "[feature-description]"
---

Creates a new feature branch using git clone for isolated development with full planning.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

## Process

### Step 1: Create Clone
Run `/create-clone $ARGUMENTS`. This also sets the terminal tab title to the feature name. Optionally tell the user they may run `/rename <name>` to also rename the session in the resume picker (`/rename` is interactive-only, so it cannot be automated).

### Step 2: Run Feature workflow
Read the file `~/.claude/feature-workflow.md` and work according to workflow.
