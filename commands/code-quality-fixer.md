# Code Quality Fixer

Automatically fix code style, ruff issues, and mypy type errors using the specialized code-quality-fixer agent. Agent works silently for routine fixes and only reports back for significant changes (new functions, major refactoring).

## Optional user instructions (can be empty for default behavior)
"$ARGUMENTS"

## Process

### Step 1: Invoke Agent
Use the Task tool with the code-quality-fixer agent, passing along any user instructions

### Step 2: Expect Silent Execution
Agent fixes all quality issues automatically. No feedback unless significant changes were made (new functions, major refactoring).
