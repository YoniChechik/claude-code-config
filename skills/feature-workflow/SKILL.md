---
name: "feature-workflow"
description: "End-to-end feature development pipeline: plan → implement → build tests → post checks → PR → summary. Invoked by /new-feature and /continue-feature. Run proactively whenever the user asks to plan a feature (run all stages after planning), or asks for a code change/debug (run all stages after implementation)."
---

# Feature Development Workflow

The workflow for developing a feature end to end — planning, implementation, testing, and post-implementation tasks.

- Each time the user asks to plan, run all stages afterwards.
- Each time the user requests a code change/debug, run all stages after implementation.

## Process

### Step 1: Plan
Run `/plan $FEATURE_DESCRIPTION` skill.

### Step 2: Implement
- Use a subagent to write code (opus high effort)
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 3: Build Tests
Run `/build-tests` skill for test planning and building.

### Step 4: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 5: PR Creation
Run `/pr-create` skill to create a pull request. This also launches the CI watcher in the background automatically.

### Step 6: Summary
Report a summary of what the feature is, how we implemented it, and what happened at all post-implementation steps.
