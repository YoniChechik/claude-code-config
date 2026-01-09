---
name: "new-feature-short"
description: "Quick Feature Setup"
---

Creates a new feature branch using git clone with lightweight planning. Uses planner with haiku model for MVP scope, skips tests and docs.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a brief description of what to build."

## Process

### Step 1: Create Clone
Run /create-clone command to set up isolated feature clone

### Step 2: Fast Plan
Use Task tool with subagent_type="planner-agent" and model="haiku" to create a quick MVP plan:
- Focus on minimal working version scope
- Skip detailed implementation steps
- Identify core components only
- Do NOT ask clarifying questions - make reasonable assumptions and document them in the plan

### Step 3: Start Implementation
According to plan
