#!/bin/bash

# cc.sh - Minimal Claude Code wrapper with validation only

CLAUDE_DIR="$HOME/.claude"
ORIG_DIR="$(pwd)"

# ============================================================
# GIT CHECKS
# ============================================================
if [ ! -d "$CLAUDE_DIR" ]; then
    echo "Error: Claude config directory does not exist at $CLAUDE_DIR" >&2
    exit 1
fi

cd "$CLAUDE_DIR" || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository at $CLAUDE_DIR" >&2
    exit 1
fi

if ! git fetch origin main >/dev/null 2>&1; then
    echo "Error: Failed to fetch origin/main" >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ]; then
    echo "Error: Detached HEAD state" >&2
    exit 1
fi

if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    echo "Error: Branch $CURRENT_BRANCH is behind or diverged from origin/main" >&2
    echo "Run: (cd ~/.claude && git pull)" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not installed" >&2
    echo "" >&2
    echo "To install jq on Ubuntu without sudo:" >&2
    echo "  apt update && apt install -y jq" >&2
    exit 1
fi

# Test mode
if [ "$CC_TEST" = "1" ]; then
    echo "✓ All checks passed (branch: $CURRENT_BRANCH)"
    exit 0
fi

cd "$ORIG_DIR" || exit 1

# ============================================================
# RUN CLAUDE
# ============================================================
# Build args
args=("$@")

# Add append-system-prompt if exists
if [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ]; then
    args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")
fi

# Run claude
exec claude "${args[@]}"
