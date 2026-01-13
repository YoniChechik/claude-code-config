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
Run the create-clone skill to set up an isolated feature branch:
/create-clone

### Step 2: Plan
Use the planner subagent to create the feature plan

### Step 3: Start Implementation
According to plan.
