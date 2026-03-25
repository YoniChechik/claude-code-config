---
name: "feature-loop-scheme"
description: "Full feature development workflow (called by new-feature/continue-feature)"
---

**Prerequisites:** Must be in a feature clone directory.

## Process

### Step 1: Plan
Run `/plan $FEATURE_DESCRIPTION` skill

### Step 2: Implement
- Use subagent to write code
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 3: Build Tests
Run `/build-tests` skill for test planning and building.

### Step 4: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 5: PR Creation
Run `/pr-create` skill to create a pull request.

### Step 6: CI Watcher
**This step is run directly by the orchestrator (exception to orchestration-only rule).**

Launch the CI watcher in background and immediately proceed to Step 7 (don't wait for results):
```
$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH
```
Run this with `run_in_background=true`.

The watcher runs silently on CI pass. It only interrupts when something needs attention (fail/timeout/conflict). When a watcher notification arrives: first relaunch the watcher with `run_in_background=true`, then delegate the fix to coder-agent.

### Step 7: Summary
Report summary of what the feature is, how we implemented it and what happened at all post implementation steps.

## How to start
ADD ALL ABOVE STEPS (Plan, Implement, Build Tests, Post, PR Creation, CI Watcher, Summary) as steps to task list and start working.
