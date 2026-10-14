#!/usr/bin/env bash

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input
mapfile -d '' fields < <(printf '%s' "$input" | jq -j '(.session_id // "" | tostring), "\u0000",
    (.hook_event_name // "" | tostring), "\u0000",
    (.agent_id // "" | tostring), "\u0000"' 2>/dev/null)
((${#fields[@]} == 3)) || exit 0
session=${fields[0]}
event=${fields[1]}
agent=${fields[2]}
[ -n "$session" ] || exit 0
[ -z "$agent" ] || exit 0
[ "$event" = PostToolUse ] || exit 0

source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_relay_lib.sh" 2>/dev/null || exit 0

relay_collect "$session" "$event"
[ -n "$RELAY_TEXT" ] || exit 0
jq -nc --arg c "$RELAY_TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
