#!/usr/bin/env bash

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

warnings=$(echo "$state" | jq -r '.warnings')
if [ -n "$warnings" ]; then
    jq -n --arg msg "$warnings" '{"systemMessage": $msg}'
fi
