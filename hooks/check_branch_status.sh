#!/bin/bash

# Get the .claude directory path
CLAUDE_DIR="$HOME/.claude"

# Helper function to output critical instruction JSON
critical_json() {
    local issue="$1"
    cat << JSON_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "CRITICAL INSTRUCTION: You MUST immediately inform the user about the following issue with their ~/.claude config repository: $issue Do NOT proceed with any other tasks until you have told the user about this."
  }
}
JSON_EOF
}

# TEST MODE: Run with CLAUDE_HOOK_TEST=1 to verify hook is working
if [ "$CLAUDE_HOOK_TEST" = "1" ]; then
    critical_json "TEST MODE ACTIVE: You MUST show this message to the user immediately in your first response. Do NOT proceed with any user request. Stop and wait for further instructions."
    exit 0
fi

# Check if .claude directory exists and is a git repository
if [ ! -d "$CLAUDE_DIR" ]; then
    critical_json "The Claude config directory does not exist at $CLAUDE_DIR. Expected a git repository with Claude configuration."
    exit 0
fi

cd "$CLAUDE_DIR" || {
    critical_json "Cannot access Claude config directory at $CLAUDE_DIR."
    exit 0
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    critical_json "Not a git repository at $CLAUDE_DIR. They should initialize with: cd ~/.claude && git init."
    exit 0
fi

# Fetch origin/main
if ! git fetch origin main >/dev/null 2>&1; then
    critical_json "Failed to fetch origin/main. They should check their network connection and git remote configuration."
    exit 0
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

# Check if we're on a branch (not detached HEAD)
if [ -z "$CURRENT_BRANCH" ]; then
    critical_json "Detached HEAD state detected. They must be on a branch. They should switch with: cd ~/.claude && git checkout main."
    exit 0
fi

# Check if we are strictly >= origin/main (equal or ahead)
if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    # origin/main is not an ancestor of HEAD - we're either behind or diverged
    
    if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        # HEAD is ancestor of origin/main - we're behind
        BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")
        critical_json "The branch $CURRENT_BRANCH is BEHIND origin/main by $BEHIND_COUNT commit(s). They should run: cd ~/.claude && git pull."
        exit 0
    else
        # Neither is ancestor of the other - we've diverged
        critical_json "The branch $CURRENT_BRANCH has DIVERGED from origin/main. Both local and remote have different commits. They should run: cd ~/.claude && git pull."
        exit 0
    fi
fi

# We're equal to or ahead of origin/main - all good
exit 0
