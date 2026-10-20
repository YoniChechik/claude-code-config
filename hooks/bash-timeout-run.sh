#!/bin/bash

CAP="$1"
MODE="$2"
TOOL_ID=$(printf '%s' "$3" | tr -cd 'A-Za-z0-9_-')
[ "$TOOL_ID" = "-" ] && TOOL_ID=""
CMD="$4"
STATE_DIR="${BASH_TIMEOUT_STATE_DIR:-$HOME/.claude/logs/bash-timeouts}"

START=$SECONDS
gtimeout --kill-after=15 "$CAP" bash -c "$CMD"
RC=$?

if { [ "$RC" = "124" ] || [ "$RC" = "137" ]; } && ((SECONDS - START >= CAP)); then
    printf '\n[bash-timeout] KILLED after %ss (exit %s, %s): the 30-minute Bash cap was hit.\n' "$CAP" "$RC" "$MODE" >&2
    mkdir -p "$STATE_DIR" 2>/dev/null
    MARKER="$STATE_DIR/$(date +%Y%m%dT%H%M%S)-$$-${TOOL_ID:-none}.json"
    jq -n --arg cmd "$CMD" --arg cap "$CAP" --arg mode "$MODE" --arg rc "$RC" --arg id "$TOOL_ID" --arg cwd "$PWD" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{killed_at:$at, exit_code:($rc|tonumber), cap_seconds:($cap|tonumber), mode:$mode, tool_use_id:$id, cwd:$cwd, command:$cmd}' >"$MARKER" 2>/dev/null
    if [ "$MODE" = "bg" ] && [ "${BASH_TIMEOUT_NOTIFY:-1}" = "1" ] && command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "Claude Code: Bash timeout" -subtitle "Background command killed after ${CAP}s" \
            -message "$(printf '%s' "$CMD" | head -c 120)" -group "claude-bash-timeout-$$" >/dev/null 2>&1 &
    fi
fi

exit "$RC"
