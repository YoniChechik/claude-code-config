#!/bin/bash

# cc.sh - Minimal Claude Code wrapper with validation only

CLAUDE_DIR="$HOME/.claude"
ORIG_DIR="$(pwd)"

# Source validation
source "$CLAUDE_DIR/bin/val.sh"
validate_environment

cd "$ORIG_DIR" || exit 1

# Source and run claude
source "$CLAUDE_DIR/bin/run.sh"
run_claude_cli "$@"
