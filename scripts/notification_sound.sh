#!/usr/bin/env bash

TYPE=$(cat | jq -r .notification_type)

if [ "$TYPE" = "idle_prompt" ]; then
    exit 0
fi

if [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

afplay /System/Library/Sounds/Glass.aiff
