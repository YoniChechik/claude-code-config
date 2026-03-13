---
name: "feature-loop-scheme"
description: "Full feature development workflow (called by new-feature/continue-feature)"
---

**Prerequisites:** Must be in a feature clone directory.

## Process

### Step 1: Plan
Run `/plan $FEATURE_DESCRIPTION` skill

### Step 2: Implement
- Use coder-agent to write code
- If problems occur, use coder-agent to fix them
- After each significant change, commit and push (main agent does this directly)
- this will be populated with more fine grained tasks after the plan will be written.

### Step 3: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 4: Review
Use Task tool with subagent_type="reviewer-agent" for final code review and validation. 

### Step 5: Fix Issues
Fix all issues found by reviewer-agent and commit/push changes.

### Step 6: PR Creation
create a pull request with "pr-create" skill

### Step 7: Summary
Report summary of what the feature is, how we implemented it and what happend at all post implementation steps 

## How to start
ADD ALL ABOVE STEPS as steps to task list and start working.
