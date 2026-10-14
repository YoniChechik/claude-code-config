#!/usr/bin/env bash

STATE_ROOT="${CLAUDE_STATE_DIR:-$HOME/.claude/state}"
STATE_DIR=""
STATE_ERR=""
DONE_GATE_KILL_TTL="${DONE_GATE_KILL_TTL:-86400}"
STATE_LOCK_TIMEOUT="${STATE_LOCK_TIMEOUT:-10}"

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

state_root_dir() {
    state_mkdir "$STATE_ROOT"
    state_safe_dir "$STATE_ROOT" || return 1
    state_safe_dir "$STATE_ROOT" 700 || chmod 700 "$STATE_ROOT" 2>/dev/null
    STATE_ERR=""
    state_safe_dir "$STATE_ROOT" 700
}

state_private_dir() {
    state_mkdir "$1"
    state_safe_dir "$1" 700
}

state_init() {
    local session=$1
    STATE_DIR=""
    STATE_ERR=""
    state_valid_session "$session" || { STATE_ERR="invalid session id"; return 1; }
    state_root_dir || return 1
    state_private_dir "$STATE_ROOT/sessions" || return 1
    state_private_dir "$STATE_ROOT/sessions/$session" || return 1
    STATE_DIR="$STATE_ROOT/sessions/$session"
    local f
    for f in ledger.jsonl ledger.lock gate.json prompt.json unresolved.json counter.json name_nudge; do
        state_safe_file "$STATE_DIR/$f" || { STATE_DIR=""; return 1; }
    done
    [[ -z $STATE_ERR ]]
}

state_read() {
    REPLY=""
    state_safe_file "$1" || return 1
    [[ -f $1 ]] || return 0
    REPLY=$(<"$1")
}

atomic_write() {
    local path=$1 tmp
    tmp=$(umask 077 && mktemp "${path%/*}/.tmp.XXXXXX") || return 1
    if ! printf '%s' "$2" >"$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
}

state_write() {
    state_safe_file "$1" || return 1
    atomic_write "$1" "$2"
}

state_ledger_file() {
    REPLY=/dev/null
    [[ -n $STATE_DIR && -f $STATE_DIR/ledger.jsonl ]] || return 0
    state_safe_file "$STATE_DIR/ledger.jsonl" || return 1
    REPLY="$STATE_DIR/ledger.jsonl"
}

ledger_append() {
    [[ -n $STATE_DIR ]] || return 1
    local file="$STATE_DIR/ledger.jsonl" lock="$STATE_DIR/ledger.lock" line
    state_safe_file "$file" && state_safe_file "$lock" || return 1
    line=$(jq -c --argjson ts "$EPOCHSECONDS" '. + {ts: (.ts // $ts)}' <<<"$1") || return 1
    [[ -n $line ]] || return 1
    printf '%s\n' "$line" | (umask 077 && lockf -k -t "$STATE_LOCK_TIMEOUT" "$lock" tee -a "$file" >/dev/null)
}

ledger_latest() {
    REPLY=""
    state_ledger_file || return 1
    REPLY=$(jq -Rc --arg k "$1" 'fromjson? | select(type == "object" and .kind == $k)' "$REPLY" | tail -n 1)
}

ledger_has_kind() {
    state_ledger_file || return 1
    jq -Rne --arg k "$1" 'any(inputs | fromjson? | select(type == "object"); .kind == $k)' "$REPLY" >/dev/null
}

state_kill_switch() {
    local dir="$STATE_ROOT/override" file="$STATE_ROOT/override/done_gate.off" mtime
    [[ -e $file || -L $file ]] || return 1
    state_safe_dir "$dir" 700 || return 1
    state_safe_file "$file" || return 1
    state_stat "$file" || return 1
    read -r _ _ mtime <<<"$REPLY"
    ((mtime <= EPOCHSECONDS && EPOCHSECONDS - mtime <= DONE_GATE_KILL_TTL))
}

