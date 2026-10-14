#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}
DONE_GATE_CAP="${DONE_GATE_CAP:-3}"

IFS= read -r -d '' input
source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_state.sh" 2>/dev/null || { hook_log "error: _state.sh missing"; exit 0; }
source "$HOOK_DIR/_relay_lib.sh" 2>/dev/null || { hook_log "error: _relay_lib.sh missing"; exit 0; }

mapfile -d '' fields < <(printf '%s' "$input" | jq -j '(.session_id // "" | tostring), "\u0000",
    (.hook_event_name // "" | tostring), "\u0000",
    (.agent_id // "" | tostring), "\u0000",
    (.stop_hook_active // false | tostring), "\u0000",
    (.prompt_id // "" | tostring), "\u0000"' 2>/dev/null)
((${#fields[@]} == 5)) || { hook_log "skip: bad hook input JSON"; exit 0; }
session=${fields[0]}
event=${fields[1]}
agent=${fields[2]}
hook_active=${fields[3]}
prompt_id=${fields[4]}
[[ -n $session && -z $agent && $event == Stop ]] || exit 0

RELAY_TEXT=""
relay_collect "$session" Stop

BLOCK_TEXT=""
SYS_TEXT=""

gate_eval() {
    local scope=$1 ledger=/dev/null gate="{}" prompt="{}" st out
    if [[ $scope == full ]]; then
        state_ledger_file || return 1
        ledger=$REPLY
        state_read "$STATE_DIR/gate.json" && [[ -n $REPLY ]] && gate=$REPLY
        state_read "$STATE_DIR/prompt.json" && [[ -n $REPLY ]] && prompt=$REPLY
    fi
    st=$(jq -nc --argjson g "$gate" --argjson p "$prompt" '{gate: $g, prompt: $p}' 2>/dev/null) || st='{}'
    out=$(printf '%s' "$input" | jq -nc --slurpfile hookin /dev/stdin --rawfile L "$ledger" --argjson st "$st" \
        --argjson now "$EPOCHSECONDS" --arg op stop -f "$HOOK_DIR/_done_gate.jq" 2>/dev/null) || return 1
    [[ -n $out ]] || return 1
    EVAL=$out
}

status_is_failure_on() {
    jq -e --arg w "$1" '.status.kind == "FAILURE" and (.status.rest | ascii_downcase | startswith($w))' <<<"$EVAL" >/dev/null 2>&1
}

require_failure() {
    local what=$1 detail=$2
    if gate_eval status && status_is_failure_on "$what"; then
        hook_log "$detail: FAILURE $what accepted"
        return 0
    fi
    if [[ $hook_active == true ]]; then
        hook_log "$detail: allowed (stop_hook_active)"
        SYS_TEXT="Stop gate: $detail. The stop was allowed because the gate already blocked once."
        return 0
    fi
    hook_log "block: $detail"
    BLOCK_TEXT="Stop gate: $detail. End the turn with \`STATUS: FAILURE $what: <what you observed>\`."
    SYS_TEXT="Stop gate: $detail."
}

COUNTER_KEY=""
COUNTER_VALUE=0

counter_load() {
    local key=$prompt_id stored
    if [[ -z $key ]] && state_read "$STATE_DIR/prompt.json" && [[ -n $REPLY ]]; then
        key=$(jq -r '.id // empty' <<<"$REPLY" 2>/dev/null)
    fi
    [[ -n $key ]] || key=session
    COUNTER_KEY=$key
    COUNTER_VALUE=0
    state_read "$STATE_DIR/counter.json" || return 1
    [[ -n $REPLY ]] || return 0
    stored=$(jq -r --arg k "$key" 'if .key == $k and ((.count | type) == "number") then .count else 0 end' <<<"$REPLY" 2>/dev/null) || stored=0
    COUNTER_VALUE=$stored
}

counter_save() {
    state_write "$STATE_DIR/counter.json" "$(jq -nc --arg k "$COUNTER_KEY" --argjson c "$1" '{key: $k, count: $c}')"
}

run_gate() {
    state_mode
    local mode=$REPLY
    if state_kill_switch; then
        hook_log "KILL_SWITCH: gate off"
        return 0
    fi
    if ! state_init "$session"; then
        hook_log "STATE_UNTRUSTED: $STATE_ERR"
        [[ $mode == enforce ]] || return 0
        require_failure state "state directory is untrusted ($STATE_ERR)"
        return 0
    fi
    if ! gate_eval full; then
        hook_log "error: gate evaluation failed"
        [[ $mode == enforce ]] || return 0
        if ledger_has_kind merge; then
            require_failure gate "internal error while checking a session with a merge"
        else
            SYS_TEXT="Stop gate error: evaluation failed, see ~/.claude/logs/hooks.log."
        fi
        return 0
    fi

    local -a parts
    mapfile -d '' parts < <(jq -j '([.violations[].rule] | unique | join(",")), "\u0000",
        (.gate | tojson), "\u0000",
        (.acks | map(tojson) | join("\n")), "\u0000",
        (if (.plain | length) > 0 then "Claimed without machine proof: " + (.plain | join(" | ")) else "" end), "\u0000",
        (.sys | join("\n")), "\u0000",
        (.violations | map(.msg) | join("\n\n")), "\u0000",
        ({rules: [.violations[] | {rule, key, msg}]} | tojson), "\u0000",
        (.bad_lines | tostring), "\u0000"' <<<"$EVAL")
    if ((${#parts[@]} != 8)); then
        hook_log "error: gate output has ${#parts[@]} parts"
        SYS_TEXT="Stop gate error: unreadable evaluation, see ~/.claude/logs/hooks.log."
        return 0
    fi
    local rules=${parts[0]} gate_new=${parts[1]} acks=${parts[2]} plain=${parts[3]} sysmsgs=${parts[4]}
    local violations=${parts[5]} unresolved=${parts[6]} bad=${parts[7]} ack
    [[ $bad == 0 ]] || hook_log "error: $bad unparseable ledger lines session=$session"
    state_write "$STATE_DIR/gate.json" "$gate_new" || hook_log "error: cannot write gate.json"

    if [[ $mode != enforce ]]; then
        if [[ -n $rules ]]; then
            hook_log "would_block rules=$rules session=$session"
        else
            hook_log "would_pass session=$session"
        fi
        return 0
    fi

    while IFS= read -r ack; do
        [[ -z $ack ]] || ledger_append "$ack" || hook_log "error: cannot record ack"
    done <<<"$acks"

    if [[ -z $rules ]]; then
        rm -f "$STATE_DIR/unresolved.json"
        hook_log "pass session=$session"
        SYS_TEXT=$sysmsgs
        [[ -z $plain ]] || SYS_TEXT+="${SYS_TEXT:+$'\n'}$plain"
        return 0
    fi

    if ! counter_load; then
        hook_log "FAIL_OPEN: cannot read the block counter ($STATE_ERR) rules=$rules session=$session"
        SYS_TEXT="Stop gate: unresolved $rules, but the block counter is unreadable, so the stop was allowed."
        return 0
    fi
    local count=$COUNTER_VALUE

    if ((count >= DONE_GATE_CAP)); then
        state_write "$STATE_DIR/unresolved.json" "$unresolved" || hook_log "error: cannot write unresolved.json"
        hook_log "CAP_HIT rules=$rules session=$session"
        SYS_TEXT="Stop gate: unresolved $rules, recorded and carried over to the next prompt."
        return 0
    fi

    count=$((count + 1))
    if ! counter_save "$count"; then
        hook_log "FAIL_OPEN: cannot save the block counter rules=$rules session=$session"
        SYS_TEXT="Stop gate: unresolved $rules, but the block counter cannot be saved, so the stop was allowed."
        return 0
    fi
    hook_log "block $count/$DONE_GATE_CAP rules=$rules session=$session"
    if ((count >= DONE_GATE_CAP)); then
        BLOCK_TEXT="Stop gate (block $count of $DONE_GATE_CAP): end now with \`STATUS: FAILURE <rule>: <what you tried and observed>\`. Still open:"$'\n\n'"$violations"
    else
        BLOCK_TEXT="Stop gate (block $count of $DONE_GATE_CAP). Fix this and continue:"$'\n\n'"$violations"
    fi
    [[ -n $sysmsgs ]] && SYS_TEXT=$sysmsgs
    return 0
}

EVAL=""
run_gate

reason=$RELAY_TEXT
[[ -n $BLOCK_TEXT ]] && reason+="${reason:+$'\n\n'}$BLOCK_TEXT"

if [[ -n $reason ]]; then
    jq -nc --arg r "$reason" --arg s "$SYS_TEXT" '{decision: "block", reason: $r} + (if $s == "" then {} else {systemMessage: $s} end)'
elif [[ -n $SYS_TEXT ]]; then
    jq -nc --arg s "$SYS_TEXT" '{systemMessage: $s}'
fi
exit 0
