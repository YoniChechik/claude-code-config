---
name: "review"
description: "Run comprehensive code review on current branch changes"
argument-hint: "[review focus area]"
---

# Review Mode

Run a comprehensive code review on current branch changes.

## Additional review focus
"$ARGUMENTS"

If provided, the above gives optional extra constraints or focus areas for the review. By default, the skill reviews all current branch changes without needing any arguments.

## Process

### Subagent 1: Review

Use a subagent to carry out the review.

**IMPORTANT**: This agent is a reviewer only - do NOT modify any code. Report issues for the separate fix phase to handle.

Before starting the review, the subagent should:

1. **Read the plan file for context**: Find and read `plan-*.md` in the current directory to understand the feature intent, expected changes, and architecture decisions.
2. The additional review focus above (if provided) gives extra constraints on what to concentrate on.

Then proceed with the full review workflow:

#### Step 1: Identify Changed Files

Check what files have been modified:
```bash
git status
git diff --name-only
```

Parse the output to get list of modified Python files.


#### Step 2: Deep Code Review

Review each modified file for:

**Security Concerns:**
- SQL injection vulnerabilities
- Unsafe data handling
- Credential exposure
- Input validation issues

**Code Quality:**
- Functions over 50 lines (should be broken down)
- Duplicated code patterns
- Missing type annotations
- Poor naming conventions
- Spaghetti code / complex control flow

**Integration Issues:**
- Breaking changes to existing APIs
- Missing error handling
- Race conditions
- Resource leaks

**Edge Cases:**
- Null/None handling
- Empty collections
- Boundary conditions
- Error scenarios

For each issue found, provide:
- File path and line number
- Severity (BLOCKING, HIGH, MEDIUM, LOW)
- Detailed explanation
- Suggested fix


#### Step 3: Generate Review Report

Create `review.md` with the following structure:

```markdown
# Code Review Report

**Date**: [Current date]
**Branch**: [Branch name]
**Reviewer**: Code Review Agent

## Summary

[High-level summary of changes and overall assessment]

**Overall Status**: APPROVED / CHANGES REQUESTED / REJECTED

## Code Review Findings

### BLOCKING Issues
[Critical issues - these MUST be fixed]

### High Priority
[Security concerns, major quality issues]

### Medium Priority
[Code quality improvements, refactoring suggestions]

### Low Priority / Suggestions
[Nice-to-have improvements, style suggestions]

## Test Results

[Test run summary and any failures]

## Files Reviewed

[List of all files checked with brief notes]

```

**Write the report to `review.md` in the current directory.**

### Subagent 2: Codex critique pass

After the review subagent writes `review.md`, get a second opinion from Codex:

- **Critique**: Invoke the `/codex` skill on the current branch diff (per its PR diff review recipe). Ask it to find things the primary review missed — bugs, security issues, design smells, untested paths, missed edge cases.
- **Triage**: Separate valid Codex findings from noise.
- **Merge**: Append the valid new findings into `review.md` under the appropriate severity sections, tagged as `(Codex)` so the fix phase picks them up.

The skill ends with the merged `review.md`. Do NOT fix anything — fixing is a separate, single-writer phase.

## Presenting findings to the user

When talking review findings through with the user in chat (not the `review.md` file itself), format each finding using the `adhd-structure` skill: 1-line summary, then a 5-line version, then deeper detail only on request.

## Important Notes

- **Be thorough and skeptical** - better to catch issues now than in production
- **Provide specific feedback** - include file:line references
- **Explain the "why"** - don't just say what's wrong, explain why it matters
- **Be constructive** - suggest fixes, not just criticism
