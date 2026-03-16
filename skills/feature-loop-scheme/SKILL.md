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

### Step 3: Test
Run `/test` skill for test planning, building, and review.

### Step 4: Quality + Review (parallel)
Run `/quality` skill AND `/review` skill simultaneously — they are independent checks (quality is code style/types/slop, review is deep code review) and can execute in parallel.

### Step 5: Fix Issues
Fix all issues found by both quality and review, then commit/push changes.

### Step 6: PR Creation
Run `/pr-create` skill to create a pull request.

### Step 7: Summary
Report summary of what the feature is, how we implemented it and what happened at all post implementation steps.

## How to start
ADD ALL ABOVE STEPS (Plan, Implement, Test, Quality+Review, Fix Issues, PR Creation, Summary) as steps to task list and start working.
