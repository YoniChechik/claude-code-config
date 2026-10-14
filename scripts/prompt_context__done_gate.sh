#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}
DONE_GATE_STATE_MAX_AGE_DAYS="${DONE_GATE_STATE_MAX_AGE_DAYS:-14}"
SESSION_NAME_LINE="Run /session-name now, and add --done '<exit predicate>' once the task is known (at least one cmd:, merged:<owner/repo>#<pr> or staging:<owner/repo> item for work that merges). Re-run it whenever the task changes. When the name is unchanged, say nothing about it."

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
    local unresolved="" ledger="" lines
    state_read "$STATE_DIR/unresolved.json" && unresolved=$REPLY
    state_read "$STATE_DIR/ledger.jsonl" && ledger=$REPLY
    lines=$(jq -nr --arg L "$ledger" --argjson in '{}' --argjson st '{}' --argjson now "$(date +%s)" --arg op pending \
        -f "$HOOK_DIR/_done_gate.jq" 2>/dev/null | jq -r '.pending[]' 2>/dev/null)
    if [[ -n $unresolved ]]; then
        lines+="${lines:+$'\n'}$(jq -r '.rules[]?.msg' <<<"$unresolved" 2>/dev/null)"
    fi
    REPLY=""
    [[ -n $lines ]] || return 0
    hook_log "carry_over: $event session=$session"
    REPLY="Unresolved from the last turn (Stop gate). Resolve these first:"$'\n'"$lines"
}

case "$event" in
    UserPromptSubmit)
        if state_init "$session"; then
            [[ -n $prompt_id ]] || prompt_id=$(printf '%s' "$prompt" | shasum -a 256 | cut -c1-16)
            state_write "$STATE_DIR/prompt.json" "$(jq -nc --arg id "$prompt_id" --argjson ts "$(date +%s)" '{id: $id, ts: $ts}')" ||
                hook_log "error: cannot write prompt.json"
        else
            hook_log "STATE_UNTRUSTED: $STATE_ERR"
        fi
        carry_over
        [[ -n $REPLY ]] || exit 0
        jq -nc --arg c "$REPLY" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
        ;;
    SessionStart)
        [[ $source_kind == startup ]] && prune_old_sessions
        state_init "$session" || hook_log "STATE_UNTRUSTED: $STATE_ERR"
        text=$SESSION_NAME_LINE
        carry_over
        [[ -n $REPLY ]] && text+=$'\n\n'"$REPLY"
        jq -nc --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
        ;;
esac
exit 0
