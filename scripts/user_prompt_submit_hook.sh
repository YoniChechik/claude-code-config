#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$SCRIPT_DIR/../CLAUDE.md"
cat "$SCRIPT_DIR/../CLAUDE_append_to_user_prompt.md"
