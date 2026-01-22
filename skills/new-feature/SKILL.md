---
name: "new-feature"
description: "Start new feature with full planning"
---

Creates a new feature branch using git clone for isolated development with full planning.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

## Process

### Step 1: Create Clone
Run the create-clone skill.

### Step 2: Plan
Use the planner subagent with opus model to create the feature plan. ask questions if needed.

### Step 3: Start Implementation
- code, commit, push with coder-agent
- if problems occur, fix, commit, push with debugger-agent

### Step 4: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 5: Reviewer
Use Task tool with subagent_type="reviewer-agent" for final code review and validation.

### Step 6: Summary
Report findings and confirm ready for PR (or list remaining issues).
