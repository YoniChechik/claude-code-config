#!/bin/bash

CLAUDE_DIR="$HOME/.claude"
ISSUES=()

# Check jq is installed (required by hooks)
if ! command -v jq >/dev/null 2>&1; then
    ISSUES+=("jq not installed. Run: brew install jq")
fi

# Check Claude directory exists
if [ ! -d "$CLAUDE_DIR" ]; then
    ISSUES+=("Claude config directory does not exist at $CLAUDE_DIR")
fi

# Check git repository
if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ISSUES+=("Not a git repository at $CLAUDE_DIR")
fi

# Fetch from origin
if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" fetch origin main >/dev/null 2>&1; then
    ISSUES+=("Failed to fetch origin/main")
fi

# Check branch status
CURRENT_BRANCH=$(git -C "$CLAUDE_DIR" branch --show-current 2>/dev/null)
if [ -d "$CLAUDE_DIR" ] && [ -z "$CURRENT_BRANCH" ]; then
    ISSUES+=("Detached HEAD state in $CLAUDE_DIR")
fi

# Check if behind origin/main
if [ -n "$CURRENT_BRANCH" ] && ! git -C "$CLAUDE_DIR" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    ISSUES+=("Behind origin/main. Run: cd ~/.claude && git pull")
fi

# Print issues if any, otherwise stay silent
if [ ${#ISSUES[@]} -gt 0 ]; then
    printf '\033[33m════════════════════════════════════════\033[0m\n'
    printf '\033[1;33m  Environment Issues\033[0m\n'
    for issue in "${ISSUES[@]}"; do
        printf '\033[31m  ✗ %s\033[0m\n' "$issue"
    done
    printf '\033[33m════════════════════════════════════════\033[0m\n'
fi

exit 0
