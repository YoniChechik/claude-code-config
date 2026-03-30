
Full feature development workflow (called by new-feature/continue-feature)

## Step 1: Plan
Run `/plan $FEATURE_DESCRIPTION` skill

## Step 2: Implement
- Use subagent to write code (opus high effort)
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

## Step 3: Build Tests
Run `/build-tests` skill for test planning and building.

## Step 4: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

## Step 5: PR Creation
Run `/pr-create` skill to create a pull request.

## Step 6: CI Watcher
Run `/ci` skill to launch the CI watcher in the background for the current branch.

## Step 7: Summary
Report summary of what the feature is, how we implemented it and what happened at all post implementation steps.

## How to start
ADD ALL ABOVE STEPS as steps to task list and start working.
