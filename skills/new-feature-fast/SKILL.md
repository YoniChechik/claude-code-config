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
Run `/ci` skill to launch the CI watcher in the background for the current branch.

### Step 6: Summary
Report what was built and the PR URL.

## How to start
ADD ALL ABOVE STEPS (Implement, Post, PR Creation, CI Watcher, Summary) as steps to task list and start working.
