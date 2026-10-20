#!/bin/bash

INPUT=$(cat)
STATE_DIR="${BASH_TIMEOUT_STATE_DIR:-$HOME/.claude/logs/bash-timeouts}"

[ "$(jq -r '.tool_name // empty' <<<"$INPUT")" = "Bash" ] || exit 0

TOOL_ID=$(jq -r '.tool_use_id // empty' <<<"$INPUT" | tr -cd 'A-Za-z0-9_-')
[ -n "$TOOL_ID" ] && [ "$TOOL_ID" != "-" ] || exit 0

FIRST_LINE=$(jq -r '[.error?, (.tool_response | strings)] | map(select(. != null)) | first // ""' <<<"$INPUT" 2>/dev/null | head -n 1)
[[ $FIRST_LINE =~ ^[Ee]xit\ code\ (124|137)$ ]] || exit 0
RC="${BASH_REMATCH[1]}"

MARKER=$(find "$STATE_DIR" -maxdepth 1 -name "*-$TOOL_ID.json" 2>/dev/null | head -n 1)
[ -n "$MARKER" ] || exit 0
[ "$(jq -r '.exit_code' "$MARKER" 2>/dev/null)" = "$RC" ] || exit 0

CAP=$(jq -r '.cap_seconds // empty' "$MARKER" 2>/dev/null)
LIMIT_TEXT="the 30-minute hard cap"
if [ -n "$CAP" ] && [ "$CAP" != "1785" ]; then
    LIMIT_TEXT="the ${CAP}-second hard cap"
fi
EVENT=$(jq -r '.hook_event_name // "PostToolUse"' <<<"$INPUT")
CTX="This Bash command was KILLED by $LIMIT_TEXT (exit $RC). Do not retry it blindly. Tell the user it was killed by that cap and is probably very long-running, log it (Linear ticket or note) so it can be picked up later, and only re-run it if you have concrete evidence it was minutes away from finishing. Marker: $MARKER"

jq -cn --arg e "$EVENT" --arg c "$CTX" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
