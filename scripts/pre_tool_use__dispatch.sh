#!/bin/bash

SCRIPT_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && SCRIPT_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' INPUT

INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARD_INTERNAL_ERROR: a PreToolUse guard failed to run to completion, so the dispatcher is failing closed. Confirm manually only if you know this command is safe, and repair the guard scripts."}}'
DECISION_PREFIX='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":'

if ! source "$SCRIPT_DIR/_hook_log.sh" 2>/dev/null || ! source "$SCRIPT_DIR/_bashparse.sh" 2>/dev/null; then
    printf '%s' "$INTERNAL_ERROR_JSON"
    exit 0
fi

bp_hook_prepare "$INPUT" || fail_closed "the dispatcher could not parse the command ($BP_ERR)"

ERR_MARK=$'\037'
RC_MARK=$'\036'

CHECK_OUT=""
CHECK_FAILED=0
run_check() {
    local raw line rc="" out="" failed=0
    raw=$(
        (script="$SCRIPT_DIR/$1"; set --; source "$script") </dev/null \
            2> >(while IFS= read -r line || [ -n "$line" ]; do printf '%s%s\n' "$ERR_MARK" "$line"; done)
        printf '\n%s%s\n' "$RC_MARK" "$?"
    )
    while IFS= read -r line; do
        case "$line" in
            "") ;;
            "$ERR_MARK"*) failed=1 ;;
            "$RC_MARK"*) rc="${line#"$RC_MARK"}" ;;
            *) out+="$line" ;;
        esac
    done <<<"$raw"
    [ "$rc" = "0" ] || failed=1
    CHECK_OUT="$out"
    CHECK_FAILED=$failed
}

run_check pre_tool_use__base_dir_protect.sh
out_base_dir=$CHECK_OUT
failed_base_dir=$CHECK_FAILED
run_check pre_tool_use__permission_guard.sh
out_permission=$CHECK_OUT
failed_permission=$CHECK_FAILED

if [ "$failed_base_dir" = "1" ] || [ "$failed_permission" = "1" ]; then
    hook_log "fail_closed: a guard failed (base_dir=$failed_base_dir permission=$failed_permission)"
    printf '%s' "$INTERNAL_ERROR_JSON"
    exit 0
fi

RANK=0
RANK_JSON=""
_rank_decision() {
    RANK=0
    RANK_JSON=""
    case "$1" in
        "") ;;
        "$DECISION_PREFIX"'"deny"'*'}}') RANK=3; RANK_JSON="$1" ;;
        "$DECISION_PREFIX"'"ask"'*'}}') RANK=2; RANK_JSON="$1" ;;
        "$DECISION_PREFIX"'"allow"'*'}}') ;;
        *) RANK=2; RANK_JSON="$INTERNAL_ERROR_JSON" ;;
    esac
}

_rank_decision "$out_base_dir"
rank_base_dir=$RANK
json_base_dir=$RANK_JSON
_rank_decision "$out_permission"
rank_permission=$RANK
json_permission=$RANK_JSON

if [ "$rank_base_dir" -ge "$rank_permission" ] && [ "$rank_base_dir" -gt 0 ]; then
    printf '%s' "$json_base_dir"
elif [ "$rank_permission" -gt 0 ]; then
    printf '%s' "$json_permission"
fi

exit 0
