#!/usr/bin/env bash
# All notification_type values (found via: strings $(readlink -f $(which claude)) | grep -oE '"[a-z_]+"' | sort -u):
#   permission_prompt                - Claude needs permission to run a tool
#   elicitation_dialog               - Claude is asking the user a question
#   idle_prompt                      - Fires after 60s of inactivity waiting for user input
#   auth_success                     - Authentication completed successfully
#   task_completed                   - A background task finished or was killed
#   background_task_status           - Status update from a running background task
#   background_task_summarize_delta  - Summary/progress update from a background task

INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r .notification_type)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$HOME/.claude/sound_debug.log"
JSON_ONE_LINE=$(echo "$INPUT" | tr '\n' ' ')

# Skip sound for non-interactive notifications
if [ "$TYPE" = "idle_prompt" ] || [ "$TYPE" = "task_completed" ]; then
    echo "$TIMESTAMP | notification_sound.sh | SKIPPED | $JSON_ONE_LINE" >> "$LOG_FILE"
    exit 0
fi

if [[ "$TYPE" == *"background"* ]]; then
    echo "$TIMESTAMP | notification_sound.sh | SKIPPED | $JSON_ONE_LINE" >> "$LOG_FILE"
    exit 0
fi

echo "$TIMESTAMP | notification_sound.sh | PLAYED | $JSON_ONE_LINE" >> "$LOG_FILE"
afplay /System/Library/Sounds/Glass.aiff
