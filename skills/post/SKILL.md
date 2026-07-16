---
name: "post"
description: "Run quality, review, and review-tests checks in parallel, then lint and format"
---

# Post: Quality Checks, Review, and Formatting

Run all post-implementation checks and fixes.

**Prerequisites:** Must be in a feature clone directory with code already implemented and tests built.

## Step 1: Quality + Review + Review Tests (parallel)
Run `/quality` skill, `/review` skill, AND `/review-tests` skill simultaneously — they are independent checks (quality is code style/types/slop, review is deep code review, review-tests is test quality) and can execute in parallel.

## Step 2: Lint & Format
After all checks and fixes from Step 1 are complete, run the quality check script to auto-format and lint:
```bash
~/.claude/scripts/quality_check.sh --fix
```
Then verify no errors remain:
```bash
~/.claude/scripts/quality_check.sh
```
If errors remain, read the files and fix manually, then re-run until clean.

Commit and push all changes.

Finally, clean up any results directories:
```bash
rm -rf quality-results review.md
```
