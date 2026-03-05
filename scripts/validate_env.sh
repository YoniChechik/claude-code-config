#!/bin/bash

CLAUDE_DIR="$HOME/.claude"
ISSUES=()

if ! command -v jq >/dev/null 2>&1; then
    ISSUES+=("jq not installed. Run: brew install jq")
fi

if [ ! -d "$CLAUDE_DIR" ]; then
    ISSUES+=("Claude config directory does not exist at $CLAUDE_DIR")
fi

if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ISSUES+=("Not a git repository at $CLAUDE_DIR")
fi

if [ -d "$CLAUDE_DIR" ] && ! git -C "$CLAUDE_DIR" fetch origin main >/dev/null 2>&1; then
    ISSUES+=("Failed to fetch origin/main")
fi

CURRENT_BRANCH=$(git -C "$CLAUDE_DIR" branch --show-current 2>/dev/null)
if [ -d "$CLAUDE_DIR" ] && [ -z "$CURRENT_BRANCH" ]; then
    ISSUES+=("Detached HEAD state in $CLAUDE_DIR")
fi

if [ -n "$CURRENT_BRANCH" ] && ! git -C "$CLAUDE_DIR" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    ISSUES+=("Behind origin/main. Run: cd ~/.claude && git pull")
fi

_print_output() {
    if [ ${#ISSUES[@]} -gt 0 ]; then
        printf '\033[33m════════════════════════════════════════\033[0m\n'
        printf '\033[1;33m  Environment Issues\033[0m\n'
        for issue in "${ISSUES[@]}"; do
            printf '\033[31m  ✗ %s\033[0m\n' "$issue"
        done
        printf '\033[33m════════════════════════════════════════\033[0m\n'
    else
        printf '\033[32m════════════════════════════════════════\033[0m\n'
        printf '\033[1;32m  Environment Check\033[0m\n'
        printf '  ✓ All checks passed\n'
        printf '\033[32m════════════════════════════════════════\033[0m\n'
    fi
}

_msg=$(_print_output | sed 's/\x1b\[[0-9;]*m//g')
_json_msg=$(printf '%s' "$_msg" | jq -Rs '.')
printf '{"systemMessage": %s}\n' "$_json_msg"

exit 0
