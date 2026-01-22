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

### Step 2: Gather Context
Use the explorer subagent to gather context about the codebase relevant to the feature:
- Explore existing code patterns and architecture
- Identify related files and components
- Understand dependencies and integration points
- Set thoroughness level to "medium" for balance between speed and depth

This context will inform the planning phase.

### Step 3: Plan
Use the planner subagent with opus model to create the feature plan. ask questions if needed.

### Step 4: Start Implementation
- code, commit, push with coder-agent
- if problems occur, fix, commit, push with debugger-agent

### Step 5: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 6: Reviewer
Use Task tool with subagent_type="reviewer-agent" for final code review and validation.

### Step 7: Summary
Report findings and confirm ready for PR (or list remaining issues).
