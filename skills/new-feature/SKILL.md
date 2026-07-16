---
name: "new-feature"
description: "Start a new feature with full planning. Use PROACTIVELY, without being asked by name, whenever the user asks to start any new feature or substantial piece of work — 'build X', 'add X feature', 'implement X', 'create X', 'let's start working on X', 'new feature' — anything beyond a trivial one-file edit."
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
Run the `/feature-workflow` skill and work according to it.
