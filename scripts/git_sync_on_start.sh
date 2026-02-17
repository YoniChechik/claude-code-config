#!/usr/bin/env bash

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

jq -n --arg msg "Git branch state: $state. Tell user current branch state and suggest running /sync if behind main or diverged." '{"systemMessage": $msg}'
