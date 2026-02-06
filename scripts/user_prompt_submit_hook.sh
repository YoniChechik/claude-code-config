#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "**GLOBAL SYSTEM PROMPT REMINDER:**"
echo ""
cat "$SCRIPT_DIR/../CLAUDE.md"
echo "**ORCHESTRATION RULES:**"
echo ""
cat "$SCRIPT_DIR/../CLAUDE_append_to_user_prompt.md"
