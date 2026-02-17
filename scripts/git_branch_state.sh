#!/usr/bin/env bash

# Read-only: reports local git branch state as JSON. No fetch, no pull, no writes.

git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git remote | grep -q '^origin$' || exit 0
branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0

diverged=false
if git rev-parse --verify "origin/$branch" &>/dev/null; then
    local_only=$(git rev-list "origin/$branch..HEAD" --count 2>/dev/null || echo 0)
    remote_only=$(git rev-list "HEAD..origin/$branch" --count 2>/dev/null || echo 0)
    if [ "$local_only" -gt 0 ] && [ "$remote_only" -gt 0 ]; then
        diverged=true
    fi
fi

behind_main=0
if [ "$branch" != "main" ] && git rev-parse --verify origin/main &>/dev/null; then
    behind_main=$(git rev-list "HEAD..origin/main" --count 2>/dev/null || echo 0)
fi

jq -n \
    --arg branch "$branch" \
    --argjson diverged "$diverged" \
    --argjson behind_main "$behind_main" \
    '{branch: $branch, diverged: $diverged, behind_main: $behind_main}'
