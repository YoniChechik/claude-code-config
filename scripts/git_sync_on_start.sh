#!/usr/bin/env bash

# Exit silently if not a git repo
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Exit silently if no "origin" remote
git remote | grep -q '^origin$' || exit 0

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0

# Exit silently if no remote tracking branch
git rev-parse --verify "origin/$branch" &>/dev/null || exit 0

if git pull --ff-only origin "$branch" &>/dev/null; then
    echo "Synced latest from origin/$branch"
else
    echo "WARNING: Branch has diverged from origin. Run 'git pull' manually to resolve."
fi

if [ "$branch" != "main" ]; then
    git fetch origin main &>/dev/null
    behind_count=$(git rev-list HEAD..origin/main --count)
    if [ "$behind_count" -gt 0 ]; then
        echo "WARNING: origin/main has $behind_count commit(s) not in your branch. Run /sync to merge latest main."
        exit 0
    fi
fi
