#!/usr/bin/env bash

git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git remote | grep -q '^origin$' || exit 0

git fetch origin &>/dev/null

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
if git rev-parse --verify "origin/$branch" &>/dev/null; then
    git pull --ff-only &>/dev/null
fi

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

warnings=$(echo "$state" | jq -r '.warnings')
if [ -n "$warnings" ]; then
    jq -n --arg msg "$warnings" '{"systemMessage": $msg}'
fi
