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
    def need($ev; $script; $label): if any(cmds($ev)[]; endswith("/scripts/" + $script)) then empty else $label end;
    [
        (if .disableAllHooks == true then "every hook (disableAllHooks)" else empty end),
        need("Stop"; "stop__coordinator.sh"; "Stop coordinator"),
        need("PostToolUse"; "post_tool_use__gh_monitor_trigger.sh"; "merge ledger trigger"),
        need("PreToolUse"; "pre_tool_use__ask_gate.sh"; "question gate"),
        need("UserPromptSubmit"; "prompt_context__done_gate.sh"; "prompt context"),
        need("SessionStart"; "prompt_context__done_gate.sh"; "session start context"),
        need("ConfigChange"; "config_change__guard.sh"; "config change guard")
    ] | join(", ")' "$file" 2>/dev/null) || { hook_log "skip: $file is not readable JSON"; exit 0; }
if [[ -z $missing ]]; then
    hook_log "allow config change: gate hooks intact"
    exit 0
fi

if state_kill_switch; then
    hook_log "KILL_SWITCH: config change allowed"
    exit 0
fi
hook_log "block config change: removes $missing"
jq -nc --arg r "The change removes the $missing hook; it is not applied to the running session. It takes effect in the next session." '{decision: "block", reason: $r}'
exit 0
