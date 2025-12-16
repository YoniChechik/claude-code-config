#!/bin/bash

# cc.sh - Minimal Claude Code wrapper with validation only

CLAUDE_DIR="$HOME/.claude"

# Source validation
source "$CLAUDE_DIR/bin/val.sh"
validate_environment

# Source and run claude
source "$CLAUDE_DIR/bin/run.sh"
run_claude_cli "$@"
