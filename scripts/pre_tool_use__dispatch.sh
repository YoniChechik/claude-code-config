#!/bin/bash

SCRIPT_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && SCRIPT_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' INPUT

INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GUARD_INTERNAL_ERROR: a PreToolUse guard crashed on this command, so the dispatcher is failing closed. Rewrite: split the command into several simpler Bash calls (one command each, literal arguments, no heredoc or eval) and retry. If a plain one-line command still hits this error, the guard scripts in ~/.claude/scripts are broken: check ~/.claude/logs/hooks.log, fix them, or stop and tell the user."}}'
DECISION_PREFIX='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":'

if ! source "$SCRIPT_DIR/_hook_log.sh" 2>/dev/null || ! source "$SCRIPT_DIR/_bashparse.sh" 2>/dev/null; then
    printf '%s' "$INTERNAL_ERROR_JSON"
    exit 0
fi

bp_hook_prepare "$INPUT"

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

deny_json() {
    REPLY=""
    case "$1" in
        "") ;;
        "$DECISION_PREFIX"'"deny"'*'}}') REPLY="$1" ;;
        *) REPLY="$INTERNAL_ERROR_JSON" ;;
    esac
}

deny_json "$out_base_dir"
if [ -z "$REPLY" ]; then
    deny_json "$out_permission"
fi
printf '%s' "$REPLY"

exit 0
