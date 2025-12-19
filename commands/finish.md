# Finish Feature

Runs quality checks before PR creation. Use when implementation is complete.

## Process

### Step 1: Quality Enforcer
Use Task tool with subagent_type="quality-enforcer" to fix code style, ruff issues, ty errors, and remove AI-generated slop.

### Step 2: Reviewer
Use Task tool with subagent_type="reviewer" for final code review and validation.

### Step 3: Summary
Report findings and confirm ready for PR (or list remaining issues).
