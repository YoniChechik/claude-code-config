#!/usr/bin/env bash

git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git remote | grep -q '^origin$' || exit 0
branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
git rev-parse --verify "origin/$branch" &>/dev/null || exit 0

messages=""

if git pull --ff-only origin "$branch" &>/dev/null; then
    messages="Synced latest from origin/$branch."
else
    messages="WARNING: Branch '$branch' has diverged from origin. Suggest user to run 'git pull' manually to resolve."
fi

if [ "$branch" != "main" ]; then
    git fetch origin main &>/dev/null
    behind_count=$(git rev-list HEAD..origin/main --count 2>/dev/null)
    if [ "$behind_count" -gt 0 ]; then
        messages="$messages WARNING: origin/main has $behind_count commit(s) not in your branch. Suggest user to run /sync to merge latest main."
    fi
fi

if [ -n "$messages" ]; then
    jq -n --arg msg "$messages" '{"systemMessage": $msg}'
fi
