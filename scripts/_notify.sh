#!/usr/bin/env bash

# Base directory for the dedup lockdirs and CI watcher state/lock files.
# Defaults to /tmp; overridable (mainly for tests) so the lockdir and CI
# state/lock paths can be redirected without touching the real /tmp. Mirrors
# ci_watch.py's TMP_DIR constant.
: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

# Walk the PPID chain to find the user's real terminal device. Hooks invoked
# from a subagent context may have a detached /dev/tty, so we climb parents
# until we hit a process attached to a real tty.
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

# Resolve the tty to write escape sequences to. Prefers the real user tty,
# falls back to /dev/tty. Echoes the chosen path on stdout.
_resolve_target_tty() {
    local target_tty
    target_tty=$(find_user_tty)
    if [ -z "$target_tty" ] || [ ! -w "$target_tty" ]; then
        target_tty=/dev/tty
    fi
    printf '%s' "$target_tty"
}

# Set the iTerm2 tab background color via the OSC 6 three-channel sequence.
# Args: <red 0-255> <green 0-255> <blue 0-255>. Writes to the resolved user
# tty. Shared by the green (notify) and blue (background) paths so the exact
# escape-sequence wiring lives in one place.
_set_tab_rgb() {
    local r=$1 g=$2 b=$3
    local target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;red;brightness;%s\a\033]6;1;bg;green;brightness;%s\a\033]6;1;bg;blue;brightness;%s\a' \
        "$r" "$g" "$b" > "$target_tty" 2>/dev/null || true
}

# --- Duplicate-ping dedup guard ---------------------------------------------
# Several hooks can fire for one logical user-attention event (e.g. Stop +
# Notification, or AskUserQuestion's PreToolUse + Notification), producing two
# chimes. We suppress the SECOND chime within a short window using an ATOMIC
# lock-directory creation (mkdir is atomic across concurrent processes — a
# read-then-write timestamp file would race). The key is scoped per
# event-type + session + tty so unrelated sessions/terminals never collide.
#
# Returns 0 (proceed / first in burst) when this is the first chime for the
# event burst, or 1 (suppress) when a recent chime already fired.
# The orange rate-limit path does NOT call this (it must always be audible).
_DEDUP_WINDOW_SECONDS=2

_dedup_should_chime() {
    local event_type="$1"

    # Key on session id + tty so concurrent sessions / terminals never collide.
    local session_id="${CLAUDE_CODE_SESSION_ID:-nosession}"
    local target_tty
    target_tty=$(_resolve_target_tty)
    # Sanitize the tty path into a filename-safe token (strip slashes).
    local tty_token="${target_tty//\//_}"
    local lockdir="${CLAUDE_NOTIFY_TMP_DIR}/notify_dedup_${event_type}_${session_id}_${tty_token}"

    # Atomic claim: mkdir succeeds for exactly one racer. If it succeeds we are
    # the first chime in this burst — schedule the lock's removal after the
    # window and proceed.
    if mkdir "$lockdir" 2>/dev/null; then
        # Detached background sleeper removes the lock after the window so the
        # NEXT genuine event (a new burst) chimes again.
        ( sleep "$_DEDUP_WINDOW_SECONDS"; rmdir "$lockdir" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
        return 0
    fi

    # mkdir failed: a lock already exists. If it is older than the window
    # (e.g. a sleeper died without cleaning up), treat it as stale, take it
    # over, and chime — so a crash can never silence chimes forever.
    local now lock_mtime age
    now=$(date +%s)
    lock_mtime=$(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)
    age=$(( now - lock_mtime ))
    if [ "$age" -ge "$_DEDUP_WINDOW_SECONDS" ]; then
        # Refresh the lock's mtime to re-open a fresh window and chime.
        touch "$lockdir" 2>/dev/null || true
        ( sleep "$_DEDUP_WINDOW_SECONDS"; rmdir "$lockdir" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
        return 0
    fi

    # A recent chime already fired for this event burst — suppress.
    return 1
}

# GREEN tab + single chime + "waiting" title: the fully-settled, needs-
# attention signal. Deduped per event-type so two hooks firing for one event
# produce exactly one chime. The optional first arg is the event-type key used
# for dedup scoping (defaults to "attention").
notify_user_attention() {
    local event_type="${1:-attention}"

    local target_tty
    target_tty=$(_resolve_target_tty)

    # Always set the green color and title even when the chime is deduped —
    # the visual state is idempotent, only the audible chime must be unique.
    _set_tab_rgb 0 180 0

    if _dedup_should_chime "$event_type"; then
        if command -v afplay >/dev/null 2>&1; then
            afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
            disown
        fi
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-repo")
    printf '\033]0;🔴 %s waiting... 🔔\007' "$branch" > "$target_tty" 2>/dev/null || true
}

# Play the attention chime UNCONDITIONALLY (bypasses the dedup guard). Used by
# the orange rate-limit path, which must always be audible and must never be
# suppressed by a concurrent Stop/Notification chime.
notify_chime_force() {
    if command -v afplay >/dev/null 2>&1; then
        afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
        disown
    fi
}

# BLUE tab, NO chime, NO title change: the main agent is free but background
# work (bg agents/tasks or actively-running CI) is still in progress.
set_blue_bar() {
    _set_tab_rgb 30 90 220
}

reset_tab_color() {
    local target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;*;default\a' > "$target_tty" 2>/dev/null || true
}

# Return 0 (CI actively running) ONLY when ALL hold:
#   (a) the CI watcher process is ALIVE (lockfile PID + kill -0 + args match),
#   (b) the state value is "running" or "merging",
#   (c) the stored <branch> prefix matches the current git branch.
# Returns 1 (non-active) when the state file is missing/empty, the watcher is
# dead (so a stale "running" from a crashed watcher can never pin blue), the
# branch mismatches, or the state is terminal.
ci_is_active() {
    local slot="${CLAUDE_CODE_SESSION_ID:-}"
    [ -n "$slot" ] || return 1

    local state_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_state_${slot}"
    [ -f "$state_file" ] || return 1

    # Read the atomically-written "<branch>:<state>" line.
    local raw
    raw=$(cat "$state_file" 2>/dev/null || true)
    [ -n "$raw" ] || return 1

    # Split "<branch>:<state>". If there is no colon, there is no branch prefix.
    local stored_branch="${raw%%:*}"
    local state_only="${raw#*:}"
    if [ "$stored_branch" = "$raw" ]; then
        return 1
    fi

    # (b) Only "running" / "merging" count as actively running.
    case "$state_only" in
        running|merging) ;;
        *) return 1 ;;
    esac

    # (c) Branch prefix must match the current git branch.
    local cur_branch
    cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -n "$cur_branch" ] || return 1
    [ "$stored_branch" = "$cur_branch" ] || return 1

    # (a) Watcher must be alive — reuse the status_line.sh liveness approach:
    # read the PID from the lockfile, kill -0 it, and confirm its args mention
    # ci_watch (so a recycled PID owned by an unrelated process can't pass).
    local lock_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_lock_${slot}"
    local watcher_pid
    watcher_pid=$(cat "$lock_file" 2>/dev/null || true)
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null \
       && ps -p "$watcher_pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
        return 0
    fi
    return 1
}
