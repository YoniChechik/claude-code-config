#!/usr/bin/env bash

TYPE=$(cat | jq -r .notification_type)

# Skip sound when Claude is waiting for user input after idle timeout
if [ "$TYPE" = "idle_prompt" ]; then
    exit 0
fi

# Skip sound for background task notifications
if [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

afplay /System/Library/Sounds/Glass.aiff
