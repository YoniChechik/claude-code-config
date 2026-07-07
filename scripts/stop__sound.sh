#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# Read the Stop hook JSON payload from stdin
INPUT=$(cat)

# Extract the transcript path from the hook payload
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# Clear the iTerm2 tab badge before painting the tab — we always want a clean
# slate (the badge is set elsewhere for done/rate-limit states). Passing an
# empty base64 payload clears any previously set badge text. Resolve the real
# tty (handles detached-tty subagent contexts) rather than hardcoding /dev/tty,
# matching the other _notify.sh emitters.
printf '\e]1337;SetBadgeFormat=\a' > "$(_resolve_target_tty)" 2>/dev/null || true

# Decision (unified state model), all handled by notify_user_attention's gate
# when given the transcript path:
#   - BLUE, NO chime  = main agent free but background work continues:
#                       bg agents/tasks still active OR CI actively running.
#   - GREEN + 1 chime = fully settled, needs attention.
notify_user_attention "$TRANSCRIPT_PATH"
