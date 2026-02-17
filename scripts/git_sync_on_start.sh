#!/usr/bin/env bash

# Startup hook: fetch + pull, then report branch state warnings.

git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git remote | grep -q '^origin$' || exit 0

git fetch origin &>/dev/null

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
if git rev-parse --verify "origin/$branch" &>/dev/null; then
    git pull --ff-only &>/dev/null
fi

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

diverged=$(echo "$state" | jq -r '.diverged')
behind_main=$(echo "$state" | jq -r '.behind_main')
branch=$(echo "$state" | jq -r '.branch')

messages=""

if [ "$diverged" = "true" ]; then
    messages="WARNING: Branch '$branch' has diverged from origin. Suggest user to run 'git pull' manually to resolve."
fi

if [ "$behind_main" -gt 0 ] 2>/dev/null; then
    messages="$messages WARNING: origin/main has $behind_main commit(s) not in your branch. Suggest user to run /sync to merge latest main."
fi

if [ -n "$messages" ]; then
    jq -n --arg msg "$messages" '{"systemMessage": $msg}'
fi
