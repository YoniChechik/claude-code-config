#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}
DONE_GATE_STATE_MAX_AGE_DAYS="${DONE_GATE_STATE_MAX_AGE_DAYS:-14}"
DONE_GATE_NAME_RECHECK_S="${DONE_GATE_NAME_RECHECK_S:-1800}"
SESSION_NAME_LINE="Run /session-name <label> now, and add --done '<exit predicate item>' once the task is known (at least one cmd:, merged:<owner/repo>#<pr> or staging:<owner/repo> item for work that merges). Re-run it whenever the task changes. When the name is unchanged, say nothing about it."

IFS= read -r -d '' input
source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_state.sh" 2>/dev/null || exit 0

mapfile -d '' fields < <(printf '%s' "$input" | jq -j '(.session_id // "" | tostring), "\u0000",
    (.hook_event_name // "" | tostring), "\u0000",
    (.agent_id // "" | tostring), "\u0000",
    (.prompt_id // "" | tostring), "\u0000",
    (.source // "" | tostring), "\u0000",
    (.prompt // "" | tostring | .[0:4000]), "\u0000"' 2>/dev/null)
((${#fields[@]} == 6)) || exit 0
session=${fields[0]}
event=${fields[1]}
agent=${fields[2]}
prompt_id=${fields[3]}
source_kind=${fields[4]}
prompt=${fields[5]}
[[ -n $session && -z $agent ]] || exit 0

prune_old_sessions() {
    [[ -d $STATE_ROOT/sessions && ! -L $STATE_ROOT/sessions ]] || return 0
    find "$STATE_ROOT/sessions" -mindepth 1 -maxdepth 1 -type d -mtime "+$DONE_GATE_STATE_MAX_AGE_DAYS" \
        -exec rm -rf {} + 2>/dev/null
}

carry_over() {
    REPLY=""
    state_mode
    [[ $REPLY == enforce ]] || { REPLY=""; return 0; }
    state_kill_switch && { REPLY=""; return 0; }
    [[ -n $STATE_DIR ]] || { REPLY=""; return 0; }
    local unresolved="" lines
    state_read "$STATE_DIR/unresolved.json" && unresolved=$REPLY
    state_ledger_file || { hook_log "STATE_UNTRUSTED: $STATE_ERR"; REPLY=""; return 0; }
    lines=$(jq -nr --rawfile L "$REPLY" --argjson hookin '[{}]' --argjson st '{}' --argjson now "$EPOCHSECONDS" --arg op pending \
        -f "$HOOK_DIR/_done_gate.jq" 2>/dev/null | jq -r '.pending[]' 2>/dev/null)
    if [[ -n $unresolved ]]; then
        lines+="${lines:+$'\n'}$(jq -r '.rules[]?.msg' <<<"$unresolved" 2>/dev/null)"
    fi
    REPLY=""
    [[ -n $lines ]] || return 0
    hook_log "carry_over: $event session=$session"
    REPLY="Unresolved from the last turn (Stop gate). Resolve these first:"$'\n'"$lines"
}

name_recheck_due() {
    [[ -n $STATE_DIR ]] || return 1
    local file="$STATE_DIR/name_nudge" last=0
    state_read "$file" || return 1
    [[ $REPLY =~ ^[0-9]+$ ]] && last=$REPLY
    if ((last == 0)); then
        state_write "$file" "$EPOCHSECONDS"
        return 1
    fi
    ((EPOCHSECONDS - last >= DONE_GATE_NAME_RECHECK_S)) || return 1
    state_write "$file" "$EPOCHSECONDS" || return 1
}

case "$event" in
    UserPromptSubmit)
        if state_init "$session"; then
            synthetic=false
            if [[ -z $prompt_id ]]; then
                synthetic=true
                prompt_id="t${EPOCHREALTIME/[.,]/}-$(printf '%s' "$prompt" | shasum -a 256 | cut -c1-16)"
            fi
            state_write "$STATE_DIR/prompt.json" "$(jq -nc --arg id "$prompt_id" --argjson ts "$EPOCHSECONDS" --argjson syn "$synthetic" \
                '{id: $id, ts: $ts, synthetic: $syn}')" || hook_log "error: cannot write prompt.json"
        else
            hook_log "STATE_UNTRUSTED: $STATE_ERR"
        fi
        text=""
        name_recheck_due && text="The session label may be stale. $SESSION_NAME_LINE"
        carry_over
        [[ -n $REPLY ]] && text+="${text:+$'\n\n'}$REPLY"
        [[ -n $text ]] || exit 0
        jq -nc --arg c "$text" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
        ;;
    SessionStart)
        [[ $source_kind == startup ]] && prune_old_sessions
        if state_init "$session"; then
            state_write "$STATE_DIR/name_nudge" "$EPOCHSECONDS" || hook_log "error: cannot write name_nudge"
        else
            hook_log "STATE_UNTRUSTED: $STATE_ERR"
        fi
        text=$SESSION_NAME_LINE
        carry_over
        [[ -n $REPLY ]] && text+=$'\n\n'"$REPLY"
        jq -nc --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
        ;;
esac
exit 0
