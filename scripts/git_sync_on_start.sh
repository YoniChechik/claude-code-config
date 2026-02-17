#!/usr/bin/env bash

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

branch=$(echo "$state" | jq -r '.branch')
pull_ok=$(echo "$state" | jq -r '.pull_ok')
behind_main=$(echo "$state" | jq -r '.behind_main')

messages=""

if [ "$pull_ok" = "false" ]; then
    messages="WARNING: Branch '$branch' has diverged from origin. Suggest user to run 'git pull' manually to resolve."
fi

if [ "$behind_main" -gt 0 ] 2>/dev/null; then
    messages="$messages WARNING: origin/main has $behind_main commit(s) not in your branch. Suggest user to run /sync to merge latest main."
fi

if [ -n "$messages" ]; then
    jq -n --arg msg "$messages" '{"systemMessage": $msg}'
fi
