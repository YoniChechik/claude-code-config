# feature development workflow 
- This document outlines the workflow for developing a new feature using the agent. It covers the steps from planning to implementation, testing, and post-implementation tasks.
- each time user asks to plan you run all stages afterwards
- each time user requests code change/debug you run all stages after implementation

## the process

### Step 1: Plan
Run `/plan $FEATURE_DESCRIPTION` skill

### Step 2: Implement
- Use subagent to write code (opus high effort)
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 3: Build Tests
Run `/build-tests` skill for test planning and building.

### Step 4: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 5: PR Creation
Run `/pr-create` skill to create a pull request. This also launches the CI watcher in the background automatically.

### Step 6: Summary
Report summary of what the feature is, how we implemented it and what happened at all post implementation steps.

