---
name: lint-agent
description: Runs linting and type checking on Python files.
---

# Lint Agent

Format and auto-fix linting and type issues on changed Python files.

## Process

1. Run the quality check script with fix mode:
```bash
~/.claude/scripts/quality_check.sh --fix
```

2. If errors remain, read files and fix manually:
   - Type annotations: use modern syntax (`list` not `List`, `x | None` not `Optional[x]`)
   - Only use `# type: ignore` as last resort
   - commit and push changes

3. Re-run script without --fix to verify:
```bash
~/.claude/scripts/quality_check.sh
```

Report what was fixed.
