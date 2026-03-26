---
name: "new-feature-fast"
description: "Fast feature development: clone → implement → PR (no planning, no tests)"
argument-hint: "[feature-description]"
---

Creates a new feature clone and goes straight to implementation then PR — skipping planning, tests, and quality checks.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required."

## Process

### Step 1: Create Clone
Run `/create-clone $ARGUMENTS`.

### Step 2: Implement
Use a subagent to implement the feature directly based on the description.
- After each significant change, commit and push.
- If problems occur, use `/debug` skill to fix them.

### Step 3: Post
Run `/post` skill for quality checks, code review, and lint/format.

### Step 4: PR Creation
Run `/pr-create` skill to create the pull request.

### Step 5: CI Watcher
**This step is run directly by the orchestrator (exception to orchestration-only rule).**

Launch the CI watcher in background and immediately proceed to Step 6 (don't wait for results):
```
$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH
```
Run this with `run_in_background=true`.

The watcher runs silently on CI pass. It only interrupts when something needs attention (fail/timeout/conflict). When a watcher notification arrives: first relaunch the watcher with `run_in_background=true`, then delegate the fix to coder-agent.

### Step 6: Summary
Report what was built and the PR URL.

## How to start
ADD ALL ABOVE STEPS (Implement, Post, PR Creation, CI Watcher, Summary) as steps to task list and start working.
