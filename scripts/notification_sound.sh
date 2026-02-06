#!/usr/bin/env bash
# notification_type values found via: strings $(readlink -f $(which claude)) | grep -oE '"[a-z_]+"' | sort -u

TYPE=$(cat | jq -r .notification_type)

# Skip sound for non-interactive notifications
if [ "$TYPE" = "idle_prompt" ] || [ "$TYPE" = "task_completed" ]; then
    exit 0
fi

if [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

afplay /System/Library/Sounds/Glass.aiff
