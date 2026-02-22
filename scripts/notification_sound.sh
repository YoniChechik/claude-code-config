#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/terminal_title.sh"

INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r .notification_type)

if [ "$TYPE" = "idle_prompt" ] || [ "$TYPE" = "task_completed" ] || [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

set_waiting_title
