#!/usr/bin/env bash

HOOK_LOG_DIR="${CLAUDE_HOOK_LOG_DIR:-$HOME/.claude/logs}"
HOOK_LOG_FILE="$HOOK_LOG_DIR/hooks.log"
HOOK_LOG_MAX_BYTES="${CLAUDE_HOOK_LOG_MAX_BYTES:-1048576}"
HOOK_LOG_CHECK_EVERY="${CLAUDE_HOOK_LOG_CHECK_EVERY:-32}"
HOOK_NAME="${HOOK_NAME:-${0##*/}}"
HOOK_LOG_CMD="${HOOK_LOG_CMD:-}"

_HOOK_Q="[\"']"
_HOOK_V="[^*\"'[:space:]]+"
_HOOK_SECRET_WORDS="token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|client[_-]?secret"

_hook_sub() {
    local re=$1 keep=$2 test_mixed=${3:-} rest=$REPLY out="" m pre k kept
    while [[ $rest =~ $re ]]; do
        m=${BASH_REMATCH[0]}
        pre=${rest%%"$m"*}
        kept=""
        for k in $keep; do kept+=${BASH_REMATCH[k]}; done
        if [[ -n $test_mixed ]] && ! [[ $m =~ [0-9] && $m =~ [a-z] && $m =~ [A-Z] ]]; then
            out+=$pre$m
        else
            out+=$pre$kept"***"
        fi
        rest=${rest#*"$m"}
    done
    REPLY=$out$rest
}

hook_redact() {
    REPLY=$1
    local had_nocase=0
    shopt -q nocasematch && had_nocase=1
    shopt -s nocasematch
    _hook_sub "(authorization[\"']?[[:space:]]*[:=][[:space:]]*$_HOOK_Q?)((bearer|basic|token)[[:space:]]+)?$_HOOK_V" "1 2"
    _hook_sub "(bearer[[:space:]]+)$_HOOK_V" "1"
    _hook_sub "([A-Za-z0-9_-]*($_HOOK_SECRET_WORDS)[A-Za-z0-9_-]*$_HOOK_Q?[[:space:]]*[=:][[:space:]]*$_HOOK_Q?)[^*\"'[:space:]&;|]+" "1"
    _hook_sub "(--?($_HOOK_SECRET_WORDS)[[:space:]]+$_HOOK_Q?)$_HOOK_V" "1"
    ((had_nocase)) || shopt -u nocasematch
    _hook_sub "(^|[^A-Za-z0-9_-])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_.-]+)" "1"
    _hook_sub "(^|[^A-Za-z0-9])[0-9a-fA-F]{32,}" "1"
    _hook_sub "[A-Za-z0-9+=_-]{32,}" "" mixed
}

_hook_log_rotate() {
    local size
    size=$(wc -c <"$HOOK_LOG_FILE" 2>/dev/null) || return 0
    if ((size > HOOK_LOG_MAX_BYTES)); then
        (umask 077; mv -f "$HOOK_LOG_FILE" "$HOOK_LOG_FILE.1"; : >>"$HOOK_LOG_FILE") 2>/dev/null
    fi
}

hook_log() {
    local reason=$1 cmd=${2-$HOOK_LOG_CMD} ts line
    printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
    hook_redact "${cmd:0:512}"
    cmd=${REPLY//\\/\\\\}
    cmd=${cmd//$'\n'/\\n}
    cmd=${cmd//$'\r'/\\r}
    cmd=${cmd//$'\t'/\\t}
    reason=${reason//$'\n'/\\n}
    line="$ts ${HOOK_NAME}[$$] ${reason:0:200} | ${cmd:0:160}"
    if [[ ! -d $HOOK_LOG_DIR ]]; then
        mkdir -p -m 700 "$HOOK_LOG_DIR" 2>/dev/null || return 0
    fi
    if [[ ! -e $HOOK_LOG_FILE ]]; then
        (umask 077; : >>"$HOOK_LOG_FILE") 2>/dev/null || return 0
    elif ((RANDOM % HOOK_LOG_CHECK_EVERY == 0)); then
        _hook_log_rotate
    fi
    printf '%s\n' "$line" >>"$HOOK_LOG_FILE" 2>/dev/null
    return 0
}

skip() {
    hook_log "skip: $1"
    exit 0
}

hook_json_str() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//[$'\001'-$'\037']/ }
    REPLY="\"$s\""
}

hook_decision() {
    hook_json_str "$2"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$REPLY"
}
