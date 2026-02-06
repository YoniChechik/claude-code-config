#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$SCRIPT_DIR/../CLAUDE_prepend_to_user_prompt.md"
cat "$SCRIPT_DIR/../CLAUDE.md"
