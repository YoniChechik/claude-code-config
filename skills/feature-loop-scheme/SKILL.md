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

### Step 2.5: Commit Plan (if just created)
If plan was just created in Step 2, commit and push it immediately so it survives session crashes:
```bash
git add plan_$FEATURE_NAME.md && git commit -m 'Add feature plan' && git push
```

### Step 3: Create Task List
Create a structured task list based on the plan or next steps:
- Break down into actionable tasks
- Use the TaskCreate tool to create the task list
- Each task should be specific and measurable
- Mark the first task as "in_progress" to begin work

### Step 4: Implement
- Code, commit, push with coder-agent
- If problems occur, fix, commit, push with debugger-agent

### Step 5: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 5.5: CI Check & Auto-Fix
Wait for GitHub Actions CI to complete and fix failures if needed:

1. Run `gh run watch --branch $(git rev-parse --abbrev-ref HEAD) --exit-status` in the background using Bash with run_in_background=true
2. While CI runs, check TaskOutput periodically (every 30 seconds)
3. **If CI passes** → Continue to Step 6
4. **If CI fails** (max 2 retry attempts):
   - Fetch failure logs: `gh run view <run-id> --log-failed`
   - Launch debugger-agent to analyze logs and fix the issue
   - After fix: commit, push, and re-run this step
5. **If CI not configured or no workflows found** → Skip and continue to Step 6

### Step 6: Review
Use Task tool with subagent_type="reviewer-agent" for final code review and validation.

### Step 7: Summary
Report findings and confirm ready for PR (or list remaining issues).
