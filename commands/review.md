# Review

Comprehensive code review using the specialized reviewer agent. Validates code quality, security, and generates a detailed `review.md` report.

## Optional user instructions (can be empty for default behavior)
"$ARGUMENTS"

User can provide:
- Specific areas to focus on
- Files to review (default: all modified files)
- Additional concerns or questions
- Any special instructions

## Process

### Step 1: Invoke Code Reviewer Agent
Use the Task tool with the reviewer agent, passing along any user instructions.

### Step 2: Review Report Generated
Agent will create `review.md` with:
- Quality check results (ruff, mypy)
- Code review findings with severity levels
- Test validation results
- Specific recommendations

The agent performs comprehensive analysis including FAIL-FAST violation checks, security review, and quality validation.

