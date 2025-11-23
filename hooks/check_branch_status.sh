#!/bin/bash

# Check if we're in a git repository
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

# Check if current branch is behind origin/main
if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    # We are ahead of or diverged from origin/main - this is fine
    exit 0
fi

# Check if origin/main is ahead of us
if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    # origin/main has commits we don't have
    BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")

    echo "WARNING: Your branch '$CURRENT_BRANCH' is behind origin/main by $BEHIND_COUNT commit(s)!" >&2
    echo "Consider running: git pull origin main" >&2
    echo "" >&2
    exit 2  # Exit code 2 = blocking error, will show stderr to Claude
fi

exit 0
