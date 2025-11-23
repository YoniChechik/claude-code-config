#!/bin/bash

# Get the .claude directory path
CLAUDE_DIR="$HOME/.claude"

# Check if .claude directory exists and is a git repository
if [ ! -d "$CLAUDE_DIR" ]; then
    echo "ERROR: Claude config directory does not exist at $CLAUDE_DIR" >&2
    echo "Expected to find a git repository with Claude configuration." >&2
    echo "" >&2
    exit 2  # Blocking error
fi

cd "$CLAUDE_DIR" || {
    echo "ERROR: Cannot access Claude config directory at $CLAUDE_DIR" >&2
    echo "" >&2
    exit 2
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: Claude config directory at $CLAUDE_DIR is not a git repository!" >&2
    echo "Initialize it with: cd $CLAUDE_DIR && git init" >&2
    echo "" >&2
    exit 2  # Blocking error
fi

# Fetch origin/main
if ! git fetch origin main >/dev/null 2>&1; then
    echo "WARNING: Failed to fetch origin/main for Claude config repository" >&2
    echo "Check your network connection and git remote configuration." >&2
    echo "" >&2
    exit 2  # Blocking error
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

# Only check if we're on a branch (not detached HEAD)
if [ -z "$CURRENT_BRANCH" ]; then
    echo "INFO: Claude config repository is in detached HEAD state" >&2
    exit 0  # Not an error, just info
fi

# Check if we are strictly >= origin/main (equal or ahead)
# First check: HEAD must be ancestor of or equal to origin/main (we're not behind)
# Second check: origin/main must be ancestor of HEAD (we're ahead or equal, not diverged)

if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    # origin/main is not an ancestor of HEAD - we're either behind or diverged

    if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        # HEAD is ancestor of origin/main - we're behind
        BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")
        echo "WARNING: Your branch '$CURRENT_BRANCH' is behind origin/main by $BEHIND_COUNT commit(s)!" >&2
        echo "Consider running: git pull origin main" >&2
    else
        # Neither is ancestor of the other - we've diverged
        echo "WARNING: Your branch '$CURRENT_BRANCH' has diverged from origin/main!" >&2
        echo "Both local and remote have different commits." >&2
        echo "Consider running: git pull origin main" >&2
    fi

    echo "" >&2
    exit 2  # Exit code 2 = blocking error, will show stderr to Claude
fi

# We're equal to or ahead of origin/main - all good
if git diff --quiet HEAD origin/main 2>/dev/null; then
    echo "INFO: Claude config repository is up to date with origin/main" >&2
else
    AHEAD_COUNT=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "unknown")
    echo "INFO: Claude config repository is ahead of origin/main by $AHEAD_COUNT commit(s)" >&2
fi

exit 0
