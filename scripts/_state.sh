#!/usr/bin/env bash

STATE_ROOT="${CLAUDE_STATE_DIR:-$HOME/.claude/state}"
STATE_DIR=""
STATE_ERR=""
DONE_GATE_KILL_TTL="${DONE_GATE_KILL_TTL:-86400}"

state_stat() {
    REPLY=$(stat -f '%u %Lp %m' "$1" 2>/dev/null) || REPLY=$(stat -c '%u %a %Y' "$1" 2>/dev/null) || return 1
}

state_safe_dir() {
    local path=$1 want_mode=${2:-}
    [[ -L $path ]] && { STATE_ERR="symlink: $path"; return 1; }
    [[ -d $path ]] || { STATE_ERR="not a directory: $path"; return 1; }
    state_stat "$path" || { STATE_ERR="cannot stat: $path"; return 1; }
    local uid mode
    read -r uid mode _ <<<"$REPLY"
    [[ $uid == "$UID" ]] || { STATE_ERR="owner $uid is not $UID: $path"; return 1; }
    [[ -z $want_mode || $mode == "$want_mode" ]] || { STATE_ERR="mode $mode is not $want_mode: $path"; return 1; }
    return 0
}

state_safe_file() {
    local path=$1
    [[ -L $path ]] && { STATE_ERR="symlink: $path"; return 1; }
    [[ -e $path ]] || return 0
    [[ -f $path ]] || { STATE_ERR="not a regular file: $path"; return 1; }
    state_stat "$path" || { STATE_ERR="cannot stat: $path"; return 1; }
    local uid
    read -r uid _ <<<"$REPLY"
    [[ $uid == "$UID" ]] || { STATE_ERR="owner $uid is not $UID: $path"; return 1; }
    return 0
}

state_valid_session() {
    [[ $1 =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

state_mkdir() {
    [[ -e $1 || -L $1 ]] || (umask 077 && mkdir -m 700 "$1" 2>/dev/null)
}

state_init() {
    local session=$1
    STATE_DIR=""
    STATE_ERR=""
    state_valid_session "$session" || { STATE_ERR="invalid session id"; return 1; }
    state_mkdir "$STATE_ROOT"
    state_safe_dir "$STATE_ROOT" || return 1
    state_mkdir "$STATE_ROOT/sessions"
    state_safe_dir "$STATE_ROOT/sessions" 700 || return 1
    state_mkdir "$STATE_ROOT/sessions/$session"
    state_safe_dir "$STATE_ROOT/sessions/$session" 700 || return 1
    STATE_DIR="$STATE_ROOT/sessions/$session"
    local f
    for f in ledger.jsonl gate.json prompt.json unresolved.json; do
        state_safe_file "$STATE_DIR/$f" || { STATE_DIR=""; return 1; }
    done
    [[ -z $STATE_ERR ]]
}

state_read() {
    REPLY=""
    state_safe_file "$1" || return 1
    [[ -f $1 ]] || return 0
    REPLY=$(cat "$1" 2>/dev/null)
}

state_write() {
    local path=$1 tmp
    state_safe_file "$path" || return 1
    tmp=$(umask 077 && mktemp "${path%/*}/.tmp.XXXXXX" 2>/dev/null) || return 1
    if ! printf '%s' "$2" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$path" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
}

ledger_append() {
    [[ -n $STATE_DIR ]] || return 1
    local file="$STATE_DIR/ledger.jsonl" line
    state_safe_file "$file" || return 1
    line=$(jq -c --argjson ts "$(date +%s)" '. + {ts: (.ts // $ts)}' <<<"$1" 2>/dev/null) || return 1
    [[ -n $line ]] || return 1
    (umask 077 && printf '%s\n' "$line" >>"$file") 2>/dev/null
}

state_mode() {
    local m=${DONE_GATE_MODE:-}
    if [[ -z $m ]]; then
        local f="$STATE_ROOT/done_gate.mode"
        if [[ -f $f ]] && state_safe_file "$f"; then
            read -r m <"$f" 2>/dev/null
        fi
    fi
    case "$m" in
        enforce) REPLY=enforce ;;
        *) REPLY=log ;;
    esac
}

state_kill_switch() {
    local dir="$STATE_ROOT/override" file="$STATE_ROOT/override/done_gate.off" mtime now
    [[ -e $file ]] || return 1
    state_safe_dir "$dir" 700 || return 1
    state_safe_file "$file" || return 1
    [[ -f $file ]] || return 1
    state_stat "$file" || return 1
    read -r _ _ mtime <<<"$REPLY"
    now=$(date +%s)
    ((now - mtime <= DONE_GATE_KILL_TTL))
}
