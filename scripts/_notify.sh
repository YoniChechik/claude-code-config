#!/usr/bin/env bash

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

find_user_tty() {
    local pid=$PPID
    while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        local tty
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty" ] && [ "$tty" != "?" ] && [ "$tty" != "??" ]; then
            echo "/dev/$tty"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

_resolve_target_tty() {
    local target_tty
    if [ -n "${CLAUDE_NOTIFY_TTY:-}" ]; then
        printf '%s' "$CLAUDE_NOTIFY_TTY"
        return 0
    fi
    target_tty=$(find_user_tty)
    if [ -z "$target_tty" ] || [ ! -w "$target_tty" ]; then
        target_tty=/dev/tty
    fi
    printf '%s' "$target_tty"
}

_set_tab_rgb() {
    local r=$1 g=$2 b=$3 target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;red;brightness;%s\a\033]6;1;bg;green;brightness;%s\a\033]6;1;bg;blue;brightness;%s\a' \
        "$r" "$g" "$b" > "$target_tty" 2>/dev/null || true
}

set_tab_yellow() {
    _set_tab_rgb 255 215 0
}

set_tab_blue() {
    _set_tab_rgb 0 0 255
}

reset_tab_color() {
    local target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;*;default\a' > "$target_tty" 2>/dev/null || true
}

_sanitize_and_cap() {
    local raw="$1"
    local LC_ALL=C
    case "$raw" in
        *[!\ -~]* | *\\* | " "* | *" ") ;;
        *) if [ "${#raw}" -le 35 ]; then printf '%s' "$raw"; return 0; fi ;;
    esac
    printf '%s' "$raw" | python3 -c '
import sys
s = sys.stdin.buffer.read().decode("utf-8", "ignore")
s = "".join(
    ch for ch in s
    if not (ord(ch) < 0x20 or ord(ch) == 0x7F or 0x80 <= ord(ch) <= 0x9F or ch == "\\")
)
sys.stdout.buffer.write(s.strip()[:35].encode("utf-8"))
' 2>/dev/null || true
}

_session_name_read() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local path="${CLAUDE_NOTIFY_TMP_DIR}/session_name_${session_id}"
    [ -f "$path" ] || return 0
    local raw
    raw=$(head -c 512 "$path" 2>/dev/null || true)
    [ -n "$raw" ] || return 0
    _sanitize_and_cap "$raw"
}

_wakeup_next_path() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 1
    printf '%s' "${CLAUDE_NOTIFY_TMP_DIR}/wakeup_next_${session_id}"
}

_wakeup_next_read() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local path
    path=$(_wakeup_next_path "$session_id") || return 0
    [ -f "$path" ] || return 0
    local raw
    raw=$(head -c 512 "$path" 2>/dev/null || true)
    [ -n "$raw" ] || return 0
    local epoch label
    epoch=$(printf '%s\n' "$raw" | sed -n '1p')
    label=$(printf '%s\n' "$raw" | sed -n '2p')
    [[ "$epoch" =~ ^[1-9][0-9]*$ ]] || return 0
    local now
    now=$(date +%s)
    [ "$epoch" -gt "$now" ] || return 0
    printf '%s\t%s' "$epoch" "$label"
}

_gh_monitor_slug() {
    printf '%s' "$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-40)"
}

_gh_monitor_key() {
    local name_with_owner="$1" target="$2"
    local identity_hash
    identity_hash=$(printf '%s' "${name_with_owner}#${target}" \
        | shasum -a 256 | cut -c1-10)
    case "$identity_hash" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *)
            echo "Error: could not compute the gh_monitor identity hash (is shasum installed?)." >&2
            return 1
            ;;
    esac
    printf '%s' "$identity_hash"
}
