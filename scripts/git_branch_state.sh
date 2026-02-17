#!/usr/bin/env bash

# Exit silently if not a git repo, no origin remote, or detached HEAD
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git remote | grep -q '^origin$' || exit 0
branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0

# Fetch latest state from origin
git fetch origin &>/dev/null

# Check if remote tracking branch exists and try pull
pull_ok=true
if git rev-parse --verify "origin/$branch" &>/dev/null; then
    if ! git pull --ff-only origin "$branch" &>/dev/null; then
        pull_ok=false
    fi
fi

# Calculate how far behind origin/main we are
behind_main=0
if [ "$branch" != "main" ] && git rev-parse --verify origin/main &>/dev/null; then
    behind_main=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo 0)
fi

jq -n \
    --arg branch "$branch" \
    --argjson pull_ok "$pull_ok" \
    --argjson behind_main "$behind_main" \
    '{branch: $branch, pull_ok: $pull_ok, behind_main: $behind_main}'
