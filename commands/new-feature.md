# New Feature Setup

Creates a new feature branch using git clone for isolated development with full planning.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

## Process

### Step 1: Create Clone
Run /create-clone command to set up isolated feature clone

### Step 2: Sync with Main
Run /sync command to ensure branch is up to date with origin/main

### Step 3: Plan
Use the planner agent to create the feature plan

**FROM NOW ALL NEW WORK SHOULD ONLY BE DONE IN THIS FEATURE DIR**
