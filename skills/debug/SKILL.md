---
name: "debug"
description: "When you get a failed result/error/user says its wrong/its a bug, use this skill to systematically debug and fix the problem.
---

# Debugging Workflow

Always work based on data. Never guess.

### 1. Understand the Error
- Identify the failing test or error scenario from trace or user report
- Gather context on expected vs actual behavior
- Read the error message and stack trace if available

### 2. Reproduce the Bug
- Add debug prints as needed to see actual values
- Create minimal test/script that reproduces the bug if one doesn't exist. Prefer not to mock anything.

### 3. Run Code to Gather Debug Data

### 4. Form Hypothesis
Based on debug data, identify likely cause:
- Logic errors (wrong algorithm/condition)
- Type errors (wrong types passed/returned)
- Edge cases (unhandled boundary conditions)
- Import/dependency errors

### 5. Fix Root Cause
- Keep fix minimal and focused
- Don't silence errors or add try/except to hide problems

### 6. Verify Fix
Run the code/tests again to verify fix.

**If test still fails: Loop back to step 2** - gather more debug data and try again.

### 7. Clean Up
Remove debug prints and test scaffolding.
