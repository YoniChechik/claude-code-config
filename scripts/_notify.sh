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
# Args: <red 0-255> <green 0-255> <blue 0-255> [target_tty]. The tty is passed
# in so callers that already resolved it don't pay for another PPID-chain walk;
# omitted (e.g. set_blue_bar) it is resolved here. Shared by the green (notify)
# and blue (background) paths so the escape-sequence wiring lives in one place.
_set_tab_rgb() {
    local r=$1 g=$2 b=$3 target_tty=${4:-}
    [ -n "$target_tty" ] || target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;red;brightness;%s\a\033]6;1;bg;green;brightness;%s\a\033]6;1;bg;blue;brightness;%s\a' \
        "$r" "$g" "$b" > "$target_tty" 2>/dev/null || true
}

# Schedule removal of a dedup lockdir after the window so the next genuine
# event chimes again. Detached so the hook returns immediately.
_schedule_lockdir_cleanup() {
    ( sleep "$_DEDUP_WINDOW_SECONDS"; rmdir "$1" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# --- Duplicate-ping dedup guard ---------------------------------------------
# Several hooks fire for one logical event (e.g. Stop + Notification), so we
# suppress a second chime within _DEDUP_WINDOW_SECONDS using an atomic mkdir
# (only one concurrent racer wins). The lock is keyed per event-type + session
# + tty. Returns 0 (chime — first in burst) or 1 (suppress).
_DEDUP_WINDOW_SECONDS=2
readonly _DEDUP_WINDOW_SECONDS

# Arg 1: event-type key. Arg 2 (optional): an already-resolved target tty;
# resolved here if omitted, so callers that already have it avoid a re-walk.
_dedup_should_chime() {
    local event_type="$1"
    local target_tty="${2:-}"
    [ -n "$target_tty" ] || target_tty=$(_resolve_target_tty)

    local session_id="${CLAUDE_CODE_SESSION_ID:-nosession}"
    # Sanitize the tty path into a filename-safe token (strip slashes).
    local tty_token="${target_tty//\//_}"
    local lockdir="${CLAUDE_NOTIFY_TMP_DIR}/notify_dedup_${event_type}_${session_id}_${tty_token}"

    # Atomic claim: mkdir succeeds for exactly one racer — that racer chimes.
    if mkdir "$lockdir" 2>/dev/null; then
        _schedule_lockdir_cleanup "$lockdir"
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
        _schedule_lockdir_cleanup "$lockdir"
        return 0
    fi

    # A recent chime already fired for this event burst — suppress.
    return 1
}

# Play the attention chime (Glass.aiff) detached, if afplay is available.
_play_chime_sound() {
    if command -v afplay >/dev/null 2>&1; then
        afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
        disown
    fi
}

# GREEN tab + single chime + "waiting" title: the fully-settled, needs-
# attention signal. Deduped per event-type so two hooks firing for one event
# produce exactly one chime. The optional first arg is the event-type key used
# for dedup scoping (defaults to "attention").
notify_user_attention() {
    local event_type="${1:-attention}"

    # Resolve the tty once and thread it to the helpers — find_user_tty walks
    # the PPID chain via ps, so we avoid repeating that on every hook fire.
    local target_tty
    target_tty=$(_resolve_target_tty)

    # Always set the green color and title even when the chime is deduped —
    # the visual state is idempotent, only the audible chime must be unique.
    _set_tab_rgb 0 180 0 "$target_tty"

    if _dedup_should_chime "$event_type" "$target_tty"; then
        _play_chime_sound
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-repo")
    printf '\033]0;🔴 %s waiting... 🔔\007' "$branch" > "$target_tty" 2>/dev/null || true
}

# Play the attention chime UNCONDITIONALLY (bypasses the dedup guard). Used by
# the orange rate-limit path, which must always be audible and must never be
# suppressed by a concurrent Stop/Notification chime.
notify_chime_force() {
    _play_chime_sound
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

# Return 0 (CI actively running) ONLY when ALL hold, checked in this order:
#   (1) the state value is "running" or "merging",
#   (2) the stored <branch> prefix matches the current git branch,
#   (3) the CI watcher process is ALIVE (lockfile PID + kill -0 + args match).
# Returns 1 (non-active) when the state file is missing/empty, the watcher is
# dead (so a stale "running" from a crashed watcher can never pin blue), the
# branch mismatches, or the state is terminal.
ci_is_active() {
    local slot="${CLAUDE_CODE_SESSION_ID:-}"
    [ -n "$slot" ] || return 1

    # Read the atomically-written "<branch>:<state>" line. cat handles the
    # missing-file case; the empty-string guard below covers missing/empty.
    local state_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_state_${slot}"
    local raw
    raw=$(cat "$state_file" 2>/dev/null || true)
    [ -n "$raw" ] || return 1

    # Split "<branch>:<state>". If there is no colon, there is no branch prefix.
    local stored_branch="${raw%%:*}"
    local state_only="${raw#*:}"
    if [ "$stored_branch" = "$raw" ]; then
        return 1
    fi

    # (1) Only "running" / "merging" count as actively running.
    case "$state_only" in
        running|merging) ;;
        *) return 1 ;;
    esac

    # (2) Branch prefix must match the current git branch.
    local cur_branch
    cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -n "$cur_branch" ] || return 1
    [ "$stored_branch" = "$cur_branch" ] || return 1

    # (3) Watcher must be alive — reuse the status_line.sh liveness approach:
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
