#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# Read the AskUserQuestion hook payload and pull out the transcript path so
# notify_user_attention keeps the tab BLUE (not green) while a background
# agent/task or CI is still running.
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

notify_user_attention "$TRANSCRIPT"
