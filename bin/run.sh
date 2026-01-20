#!/bin/bash

# run.sh - Build args and run claude CLI

run_claude_cli() {
    local CLAUDE_DIR="$HOME/.claude"
    local args=("$@")

    # Add verbose flag
    # args+=(--verbose)

    # Add append-system-prompt if exists
    if [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ]; then
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")
    fi

    # Run claude
    exec claude "${args[@]}"
}
