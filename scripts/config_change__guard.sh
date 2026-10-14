#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input
source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_state.sh" 2>/dev/null || exit 0

mapfile -d '' fields < <(printf '%s' "$input" | jq -j '(.source // "" | tostring), "\u0000",
    (.file_path // "" | tostring), "\u0000"' 2>/dev/null)
((${#fields[@]} == 2)) || exit 0
[[ ${fields[0]} == user_settings ]] || exit 0
file=${fields[1]:-$HOME/.claude/settings.json}

missing=$(jq -r '
    def cmds($ev): [(.hooks[$ev] // [])[] | (.hooks // [])[] | select((.async // false) | not) | (.command // "")];
    [
        (if any(cmds("Stop")[]; endswith("/scripts/stop__coordinator.sh")) then empty else "Stop coordinator" end),
        (if any(cmds("PostToolUse")[]; endswith("/scripts/post_tool_use__gh_monitor_trigger.sh")) then empty else "merge ledger trigger" end),
        (if any(cmds("PreToolUse")[]; endswith("/scripts/pre_tool_use__ask_gate.sh")) then empty else "question gate" end)
    ] | join(", ")' "$file" 2>/dev/null) || { hook_log "skip: $file is not readable JSON"; exit 0; }
[[ -n $missing ]] || exit 0

state_mode
if [[ $REPLY != enforce ]]; then
    hook_log "would_block config change: removes $missing"
    exit 0
fi
if state_kill_switch; then
    hook_log "KILL_SWITCH: config change allowed"
    exit 0
fi
hook_log "block config change: removes $missing"
jq -nc --arg r "The change removes the $missing hook; it is not applied to the running session. It takes effect in the next session." '{decision: "block", reason: $r}'
exit 0
