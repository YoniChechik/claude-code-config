---
name: "finish"
description: "Finish Feature"
---

Runs quality checks before PR creation. Use when implementation is complete.

## Process

### Step 1: Quality
Run quality skill to fix code style, types, and remove AI slop.

### Step 2: Reviewer
Use Task tool with subagent_type="reviewer-agent" for final code review and validation.

### Step 3: Summary
Report findings and confirm ready for PR (or list remaining issues).
