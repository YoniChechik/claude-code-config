# Quick Feature Setup

Creates a new feature branch using git clone with lightweight planning. Uses fast planning for MVP scope, skips tests and docs.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a brief description of what to build."

## Process

### Step 1: Create Clone
Run /create-clone command to set up isolated feature clone

### Step 2: Fast Plan
Use Task tool with subagent_type="fast-planner" and model="haiku" to create a quick MVP plan:
- Focus on minimal working version scope
- Skip detailed implementation steps
- Identify core components only

### Step 3: Start Implementation
Begin MVP implementation following the plan:
- Build core functionality from plan
- Iterate quickly with user feedback

**FROM NOW ALL NEW WORK SHOULD ONLY BE DONE IN THIS FEATURE DIR**
