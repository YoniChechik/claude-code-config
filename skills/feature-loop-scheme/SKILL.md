---
name: "feature-loop-scheme"
description: "Full feature development workflow (called by feature-new/feature-continue)"
---

**Prerequisites:** Must be in a feature clone directory.

## Process

### Step 1: Gather Context
Use the explorer subagent to gather context about the codebase relevant to the feature:
- Explore existing code patterns and architecture
- Identify related files and components
- Understand dependencies and integration points
- Set thoroughness level to "medium" for balance between speed and depth

This context will inform the planning phase.

### Step 2: Plan or Analyze
Determine feature name from branch: `FEATURE_NAME=$(git rev-parse --abbrev-ref HEAD)`
- **If plan_$FEATURE_NAME.md doesn't exist** → Create plan using planner subagent with opus model, ask questions if needed
- **If plan_$FEATURE_NAME.md exists** → Analyze current progress compared to origin/main, examine plan_$FEATURE_NAME.md and documentation, identify next steps
- commit and push plan/analysis results

### Step 3: Implement
- Use coder-agent to write code
- If problems occur, use coder-agent to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 4: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 5: Review
Use Task tool with subagent_type="reviewer-agent" for final code review and validation. 

### Step 6: Fix Issues
Fix all issues found by reviewer-agent and commit/push changes.

### Step 7: PR Creation
create a pull request with "pr-create" skill

### Step 8: Summary
Report summary of what the feature is, how we implemented it and what happend at all post implementation steps 

## How to start
Add all plan tasks + steps 4-8 as steps to task list and start working.
