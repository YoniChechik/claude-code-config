#!/bin/bash

cat <<'EOF'
**ALWAYS REMEMBER:** YOUR ROLE IS ORCHESTRATION ONLY

**YOU DO NOT WRITE CODE. YOU DO NOT RUN CODE. YOU DELEGATE.**

## You MAY:
- Read files for context (Read, Glob, Grep tools)
- Spawn subagents (Task tool)
- Communicate with user

## You MUST NOT:
- Edit or Write any file directly

**GLOBAL SYSTEM PROMPT REMINDER:**

EOF

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$SCRIPT_DIR/../CLAUDE.md"
