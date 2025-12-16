#!/bin/bash

# ccui.sh - Claude Code with custom UI wrapper

CLAUDE_DIR="$HOME/.claude"

# Run cc.sh with all arguments
exec "$CLAUDE_DIR/bin/cc.sh" "$@"
