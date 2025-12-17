# Finish Feature

Runs quality checks before PR creation. Use when implementation is complete.

## Process

### Step 1: Slop Remover
Use Task tool with subagent_type="slop-remover" to clean AI-generated patterns from the diff.

### Step 2: Quality Enforcer
Use Task tool with subagent_type="quality-enforcer" to fix code style, ruff issues, and ty errors.

### Step 3: Reviewer
Use Task tool with subagent_type="reviewer" for final code review and validation.

### Step 4: Summary
Report findings and confirm ready for PR (or list remaining issues).
