---
name: "post"
description: "Run quality, review, and review-tests checks in parallel, then fix, lint and format"
---

# Post: Quality Checks, Review, and Formatting

Run all post-implementation checks and fixes.

**Prerequisites:** Must be in a feature worktree directory with code already implemented and tests built.

## Step 1: Quality + Review + Review Tests (parallel)
Run `/quality` skill, `/review` skill, AND `/review-tests` skill simultaneously — they are independent checks (quality is code style/types/slop, review is deep code review, review-tests is test quality) and can execute in parallel.

## Step 2: Fix (single writer)
The Step 1 skills are analysis-only; they produce findings, not edits. After all three complete, spawn ONE fix agent (opus, high effort) that owns every edit. It is a single writer on purpose: concurrent fixers race and clobber each other's edits.

Instruct the fix agent to:
1. Read all three findings artifacts: every file in `quality-results/`, plus `review.md` and `test-review.md`.
2. **Dedupe**: multiple skills often flag the same code location or the same problem — keep one entry.
3. **Print the consolidated list** before fixing.
4. **Verify each finding against the actual code before applying it.** Peer findings have been wrong — one claimed a regex hole that did not exist, and "fixing" it would have introduced one. Skip findings that don't hold up, and say which.
5. Apply the remaining fixes **serially**, one at a time. If a fix moves code referenced by a later finding, re-read the affected file. Skip findings already resolved by an earlier fix.
6. Briefly summarize what was fixed and what was rejected.

## Step 3: Lint, Format, Test, Ship
After the fix agent is done, run the quality check script to auto-format and lint:
```bash
~/.claude/skills/post/quality_check.sh --fix
```
Then verify no errors remain:
```bash
~/.claude/skills/post/quality_check.sh
```
If errors remain, read the files and fix manually, then re-run until clean.

Run the project's tests and make sure they pass.

Commit and push all changes.

Finally, clean up the findings artifacts:
```bash
rm -rf quality-results review.md test-review.md
```
