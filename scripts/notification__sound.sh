#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/notify_waiting.sh"

INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r .notification_type)

if [ "$TYPE" = "task_completed" ] || [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

notify_waiting
