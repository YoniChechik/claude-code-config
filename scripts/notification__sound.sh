#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r .notification_type)

# Optional diagnostic logging (gated behind a debug env var — never always-on)
# to inspect which notification_type values reach this hook when chasing
# duplicate-ping reports.
if [ "${CLAUDE_DEBUG_NOTIFY:-}" = "1" ]; then
    mkdir -p "$HOME/.claude/logs"
    printf '%s notification_type=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$TYPE" \
        >> "$HOME/.claude/logs/notify_debug.log"
fi

# Suppress notification types that do NOT need an audible attention chime:
#   - idle_prompt / task_completed: background/idle signals, not "come back now".
#   - *background*: background-task notifications, handled by the blue-bar path.
# Genuine attention types (e.g. permission prompts) fall through to the chime,
# which is deduped via the shared "attention" key in notify_user_attention so a
# concurrent Stop or AskUserQuestion hook for the same event chimes only once.
if [ "$TYPE" = "idle_prompt" ] || [ "$TYPE" = "task_completed" ] || [[ "$TYPE" == *"background"* ]]; then
    exit 0
fi

# Extract the transcript path so notify_user_attention can keep the tab BLUE
# (not green) while a background agent/task or CI is still running.
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

notify_user_attention "$TRANSCRIPT"
