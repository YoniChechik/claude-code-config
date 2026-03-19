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

### Subagent 1: Review (coder-agent)

Use a subagent with `subagent_type="coder-agent"` to carry out the review.

**IMPORTANT**: This agent is a reviewer only - do NOT modify any code. Report issues for the fix agent to handle.

Before starting the review, the subagent should:

1. **Read the plan file for context**: Find and read `plan-*.md` in the current directory to understand the feature intent, expected changes, and architecture decisions.
2. The additional review focus above (if provided) gives extra constraints on what to concentrate on.

Then proceed with the full review workflow:

### Step 1: Identify Changed Files

Check what files have been modified:
```bash
git status
git diff --name-only
```

Parse the output to get list of modified Python files.

### Step 2: Start Tests in Background

**IMPORTANT**: Immediately identify and start relevant tests running in the background in parallel, BEFORE proceeding with quality checks and code review.

**Identify test files for changed modules:**
```bash
# Find test files matching modified modules
find tests -name "test_*.py" | grep <module_name>
```

**Start all relevant test suites in background in parallel:**
```bash
# Example: Start pytest for each relevant test module in background
uv run pytest path/to/relevant/tests -n auto -v
```

This allows tests to execute while you perform quality checks and code review. You'll check the results later in Step 4.

**MAKE SURE TO RUN TESTS IN BACKGROUND**

### Step 3: Deep Code Review

Review each modified file for:

**CRITICAL: FAIL-FAST VIOLATIONS (BLOCKING)**
Check for forbidden defensive patterns that hide errors:
- `dict.get(key, default)` - Must use `dict[key]`
- `hasattr()` / `getattr()` - Must use direct attribute access
- `isinstance()` checks for expected types - Let code fail naturally
- `if len(items) > 0:` - Just access `items[0]`
- `value = x or default` - Must use explicit None check
- `try/except` blocks that catch and continue - Must let exceptions propagate
- Any other patterns from coding_style.md FAIL-FAST section

**These are BLOCKING issues - code with these patterns must be rejected.**

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

**Performance:**
- Inefficient algorithms
- Unnecessary computation
- Memory leaks
- N+1 query patterns

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

### Step 4: Check Test Results

By now, the background tests from Step 2 should be complete or nearly complete.

**Check the test output:**
```bash
# Check status of background tests or view their output
```

Report:
- Tests run
- Pass/fail status
- Any failures or warnings
- Coverage gaps

If tests are still running, wait for them to complete before proceeding to the report.

### Step 5: Review Git Diff

Get the actual changes:
```bash
git diff
```

Review the diff to ensure:
- Changes match intended purpose
- No debug code left in
- No commented-out code
- Clean commit hygiene

### Step 6: Generate Review Report

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
[All FAIL-FAST violations and critical issues - these MUST be fixed]

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

### Subagent 2: Fix (coder-agent)

After the review subagent completes, use another subagent with `subagent_type="coder-agent"` to fix all issues:

1. Read `review.md` in the current directory
2. Fix all BLOCKING and HIGH priority issues found in the review
3. Briefly summarize what was fixed

## Important Notes

- **Be thorough and skeptical** - better to catch issues now than in production
- **FAIL-FAST violations are non-negotiable** - always mark as BLOCKING
- **Provide specific feedback** - include file:line references
- **Explain the "why"** - don't just say what's wrong, explain why it matters
- **Be constructive** - suggest fixes, not just criticism
