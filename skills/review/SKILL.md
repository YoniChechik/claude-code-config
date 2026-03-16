---
name: "review"
description: "Run comprehensive code review on current branch changes"
argument-hint: "[feature-description]"
---

# Review Mode

Run a comprehensive code review on current branch changes.

## Feature description from user input
"$ARGUMENTS"

## Process

Use a subagent with `subagent_type="reviewer-agent"` to carry out the review.

Before starting the review, the subagent should:

1. **Read the plan file for context**: Find and read `plan-*.md` in the current directory to understand the feature intent, expected changes, and architecture decisions.
2. **Proceed with the full review workflow** as defined in `agents/reviewer-agent.md` — identify changed files, run tests in background, deep code review, check test results, review git diff, and generate `review.md`.

The feature description above (if provided) gives additional context about what was built and why.
