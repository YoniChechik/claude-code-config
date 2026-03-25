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

### Step 3: Build Tests
Run `/build-tests` skill for test planning and building.

### Step 4: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 5: PR Creation
Run `/pr-create` skill to create a pull request.

### Step 6: CI Watcher
**This step is run directly by the orchestrator (exception to orchestration-only rule).**

1. Launch the CI watcher in background:
   ```
   $HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH
   ```
   Run this with `run_in_background=true`.

2. The watcher reports CI results as they arrive:
   - **CI passed**: The watcher keeps running. Proceed to Step 7 (Summary).
   - **CI failed, timeout, or merge conflict**: The watcher exits. First relaunch the CI watcher with `run_in_background=true`, then delegate the fix to coder-agent. The relaunched watcher will automatically pick up the new push after the fix.

### Step 7: Summary
Report summary of what the feature is, how we implemented it and what happened at all post implementation steps.

## How to start
ADD ALL ABOVE STEPS (Plan, Implement, Build Tests, Post, PR Creation, CI Watcher, Summary) as steps to task list and start working.
