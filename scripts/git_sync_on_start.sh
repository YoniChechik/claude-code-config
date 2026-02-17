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
