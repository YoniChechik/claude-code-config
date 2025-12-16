#!/bin/bash

# val.sh - Validation checks for Claude Code environment

validate_environment() {
    local CLAUDE_DIR="$HOME/.claude"

    # Check Claude directory exists
    if [ ! -d "$CLAUDE_DIR" ]; then
        echo "Error: Claude config directory does not exist at $CLAUDE_DIR" >&2
        exit 1
    fi

    # Check git repository
    if ! git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Error: Not a git repository at $CLAUDE_DIR" >&2
        exit 1
    fi

    # Fetch from origin
    if ! git -C "$CLAUDE_DIR" fetch origin main >/dev/null 2>&1; then
        echo "Error: Failed to fetch origin/main" >&2
        exit 1
    fi

    # Check branch status
    local CURRENT_BRANCH=$(git -C "$CLAUDE_DIR" branch --show-current 2>/dev/null)
    if [ -z "$CURRENT_BRANCH" ]; then
        echo "Error: Detached HEAD state" >&2
        exit 1
    fi

    # Check if behind origin/main
    if ! git -C "$CLAUDE_DIR" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
        echo "Error: Branch $CURRENT_BRANCH is behind or diverged from origin/main" >&2
        echo "Run: (cd ~/.claude && git pull)" >&2
        exit 1
    fi
}
