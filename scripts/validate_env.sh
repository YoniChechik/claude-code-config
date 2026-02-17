#!/bin/bash

CLAUDE_DIR="$HOME/.claude"
ISSUES=""

add_issue() {
    if [ -n "$ISSUES" ]; then
        ISSUES="$ISSUES\n$1"
    else
        ISSUES="$1"
    fi
}

# Check jq is installed (required by hooks)
if ! command -v jq >/dev/null 2>&1; then
    add_issue "jq is not installed. Run: brew install jq"
    # Can't output JSON without jq, so just exit silently
    exit 0
fi

# Check Claude directory exists
if [ ! -d "$CLAUDE_DIR" ]; then
    add_issue "Claude config directory does not exist at $CLAUDE_DIR"
fi

# Check git repository
if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    add_issue "Not a git repository at $CLAUDE_DIR"
fi

# Fetch from origin
if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" fetch origin main >/dev/null 2>&1; then
    add_issue "Failed to fetch origin/main"
fi

# Check branch status
CURRENT_BRANCH=$(git -C "$CLAUDE_DIR" branch --show-current 2>/dev/null)
if [ -d "$CLAUDE_DIR" ] && [ -z "$CURRENT_BRANCH" ]; then
    add_issue "Detached HEAD state in $CLAUDE_DIR"
fi

# Check if behind origin/main
if [ -n "$CURRENT_BRANCH" ] && ! git -C "$CLAUDE_DIR" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    add_issue "Branch $CURRENT_BRANCH is behind or diverged from origin/main. Run: (cd ~/.claude && git pull)"
fi

# Output JSON systemMessage if any issues found
if [ -n "$ISSUES" ]; then
    jq -n --arg msg "Environment issues found:\n$ISSUES" '{"systemMessage": $msg}'
fi

exit 0
