#!/usr/bin/env bash

INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r .notification_type)

if [ "$TYPE" = "idle_prompt" ] || [ "$TYPE" = "task_completed" ] || [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

afplay /System/Library/Sounds/Glass.aiff
