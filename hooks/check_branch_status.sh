#!/bin/bash

# Get the .claude directory path
CLAUDE_DIR="$HOME/.claude"

# Check if .claude directory exists and is a git repository
if [ ! -d "$CLAUDE_DIR" ]; then
    exit 0  # .claude dir doesn't exist
fi

cd "$CLAUDE_DIR" || exit 0

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0  # Not a git repo, nothing to check
fi

# Fetch origin/main silently
git fetch origin main >/dev/null 2>&1 || exit 0

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

# Only check if we're on a branch (not detached HEAD)
if [ -z "$CURRENT_BRANCH" ]; then
    exit 0
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
exit 0
