#!/usr/bin/env bash

INPUT=$(cat)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$HOME/.claude/sound_debug.log"
JSON_ONE_LINE=$(echo "$INPUT" | tr '\n' ' ')

echo "$TIMESTAMP | stop_sound.sh | PLAYED | $JSON_ONE_LINE" >> "$LOG_FILE"
afplay /System/Library/Sounds/Glass.aiff
