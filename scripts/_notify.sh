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
#
# CLAUDE_NOTIFY_TTY overrides the PPID walk entirely. It is the seam the tests
# use to capture the raw OSC bytes a hook SUBPROCESS emits: an exported bash
# function cannot do it (sourcing _notify.sh redefines this function in the
# child), so without an env override the escape sequences are unassertable and
# tests can only check indirect side effects like the dedup lockdir.
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

# Close every open file descriptor above stderr (fd 0/1/2) in the CURRENT
# shell. Meant to be the first statement inside a detached background
# subshell, so a forked cleanup/playback job releases whatever EXTRA
# descriptors it inherited from its caller (a bats test's own captured pipe,
# a hook's inherited fd) rather than holding them open for as long as the
# background job runs. Without this a caller with such a descriptor open can
# never see EOF on it — e.g. a test's FIFO writer stays "open" because a
# detached 10s cleanup sleep still holds a copy, long after the caller closed
# its own. Best-effort: any failure to close a given fd is swallowed.
_close_extra_fds() {
    local fd_path fd
    for fd_path in /dev/fd/*; do
        fd="${fd_path##*/}"
        # Skip stdin/stdout/stderr, and skip any non-numeric entry — which is
        # what `fd` holds when /dev/fd does not exist and the glob stays
        # unexpanded as the literal "*". Everything reaching `eval` is
        # therefore a plain fd number above 2.
        case "$fd" in
            ''|0|1|2|*[!0-9]*) continue ;;
        esac
        eval "exec ${fd}>&-" 2>/dev/null
    done
    return 0
}

# Schedule removal of a dedup lockdir after the window so the next genuine
# event chimes again. Detached so the hook returns immediately.
_schedule_lockdir_cleanup() {
    ( _close_extra_fds; sleep "$_DEDUP_WINDOW_SECONDS"; rmdir "$1" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# --- Duplicate-ping dedup guard ---------------------------------------------
# Several hooks fire for one logical user-facing moment (e.g. the PreToolUse
# AskUserQuestion/permission hook AND a Notification hook, or Stop AND a
# Notification), so we suppress the extra chime within _DEDUP_WINDOW_SECONDS
# using an atomic mkdir (only one concurrent racer wins).
#
# The lock is keyed per event-type + SESSION. It is deliberately NOT keyed on
# the tty: the separate hook processes climb different PPID chains and can
# resolve DIFFERENT ttys, which produced two distinct lockdirs and a DOUBLE
# chime. The session id (CLAUDE_CODE_SESSION_ID) is identical across every hook
# of one Claude session, so it collapses them to a single chime. Only when no
# session id is available do we fall back to the tty so two concurrent terminals
# don't cross-suppress each other's chimes.
# Returns 0 (chime — first in burst) or 1 (suppress).
_DEDUP_WINDOW_SECONDS=10
readonly _DEDUP_WINDOW_SECONDS

# Arg 1: event-type key. Arg 2 (optional): an already-resolved target tty;
# resolved here if omitted, so callers that already have it avoid a re-walk.
_dedup_should_chime() {
    local event_type="$1"
    local target_tty="${2:-}"
    [ -n "$target_tty" ] || target_tty=$(_resolve_target_tty)

    # Prefer the stable per-session scope; fall back to the tty only when there
    # is no session id (sanitized into a filename-safe token by stripping /).
    local session_id="${CLAUDE_CODE_SESSION_ID:-}"
    local scope
    if [ -n "$session_id" ]; then
        scope="$session_id"
    else
        scope="${target_tty//\//_}"
    fi
    local lockdir="${CLAUDE_NOTIFY_TMP_DIR}/notify_dedup_${event_type}_${scope}"

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

# --- Last-painted tab state -------------------------------------------------
# The escape sequences are write-only: a terminal cannot be asked what colour a
# tab currently has. So the painters record what they last painted, and the
# PostToolUse reset hook consults that record to decide whether there is a green
# to clear. Without it the reset would have to fire blindly on every tool call,
# which would also wipe the BLUE background-work bar (a background agent's own
# tool calls would erase the very bar that says it is running).
# Keyed per session so two terminals never read each other's state.
_tab_state_file() {
    printf '%s/notify_tabstate_%s' \
        "$CLAUDE_NOTIFY_TMP_DIR" "${CLAUDE_CODE_SESSION_ID:-nosession}"
}

# Record the state just painted ("green" | "blue"). Best-effort: a failure here
# must never change the caller's exit code or its visible behaviour.
_set_tab_state() {
    printf '%s' "$1" > "$(_tab_state_file)" 2>/dev/null || true
}

# Echo the last painted state, or nothing if none was recorded.
tab_state() {
    cat "$(_tab_state_file)" 2>/dev/null || true
}

# Play the attention chime (Glass.aiff) detached, if afplay is available.
_play_chime_sound() {
    if command -v afplay >/dev/null 2>&1; then
        ( _close_extra_fds; afplay /System/Library/Sounds/Glass.aiff ) </dev/null >/dev/null 2>&1 &
        disown
    fi
}

# --- Session name (the /session-name skill's per-session label) --------------
# THE single implementation of the sanitize-and-cap contract every session-name
# site shares: this file, scripts/status_line.sh (which sources this file), and
# skills/session-name/SKILL.md (which also sources this file). Do not re-inline
# a copy anywhere — the whole point is that there is exactly one of these.
#
# Contract: drop C0 control bytes (0x00-0x1F, which covers raw ESC/BEL/newline/
# tab), DEL (0x7F), C1 (0x80-0x9F), and the backslash character; trim
# leading/trailing whitespace; cap at 35 Unicode CODEPOINTS — never a bash
# byte-slice like ${name:0:35}, which can split a multi-byte UTF-8 character.
#
# Backslash is stripped because stripping raw control bytes alone is NOT
# enough: any renderer that expands backslash escapes (printf '%b', echo -e)
# turns purely-printable text such as `\033]0;PWNED\007` back into a genuine
# escape sequence. Removing 0x5C closes that at the source, independently of
# what each consumer does at print time.
#
# The value reaches python on STDIN as raw bytes, never as an argv string.
# argv would (a) exceed ARG_MAX on an oversized sidecar file, which aborts the
# caller, and (b) decode invalid UTF-8 with surrogateescape, yielding lone
# surrogates that raise UnicodeEncodeError on output. Decoding the bytes here
# with errors="ignore" drops malformed bytes cleanly instead.
_sanitize_and_cap() {
    local raw="$1"
    # Fast path, zero forks: a short plain-ASCII label carrying no backslash
    # and no edge whitespace is already in its final form. status_line.sh calls
    # this on a ~1/second poll, so avoiding a python start-up here is worth the
    # extra branch. `local LC_ALL=C` makes the range a pure BYTE test (and is
    # restored on return), so every multi-byte or invalid byte takes the slow
    # path below rather than being wrongly waved through.
    local LC_ALL=C
    case "$raw" in
        *[!\ -~]* | *\\* | " "* | *" ") ;;
        *) if [ "${#raw}" -le 35 ]; then printf '%s' "$raw"; return 0; fi ;;
    esac
    # Bytes in on stdin, bytes out on stdout: neither direction goes through a
    # locale-dependent text encoder, so the LC_ALL=C set above for the fast-path
    # test cannot make a multi-byte result unprintable.
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

# Echo the sanitized+capped session name stored for session id $1 (the
# `/session-name` skill's sidecar at
# "${CLAUDE_NOTIFY_TMP_DIR}/session_name_<session_id>").
#
# NO fallback of any kind: a missing session id, a missing/empty/non-regular
# sidecar file, or a name that sanitizes down to nothing all echo nothing
# (empty, exit 0). The caller must then skip the title/segment entirely rather
# than substituting a git branch, a worktree name, or any other value.
_session_name_read() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local path="${CLAUDE_NOTIFY_TMP_DIR}/session_name_${session_id}"
    # Regular files only. The path is predictable and lives in a shared /tmp,
    # so a FIFO or socket planted there would block `cat` (and with it the
    # 1s-interval status-line poll) forever.
    [ -f "$path" ] || return 0
    # Byte cap taken BEFORE the value is handed to anything else, so a runaway
    # or corrupt multi-megabyte sidecar degrades to a truncated name instead of
    # being slurped into memory on every poll. 512 bytes is far more than 35
    # codepoints can ever need (4 bytes maximum per codepoint).
    local raw
    raw=$(head -c 512 "$path" 2>/dev/null || true)
    [ -n "$raw" ] || return 0
    _sanitize_and_cap "$raw"
}

# The title to paint for THIS session: the current session's stored name, or
# nothing at all. Callers must not emit an OSC title write when it is empty.
_display_title() {
    _session_name_read "${CLAUDE_CODE_SESSION_ID:-}"
}

# GREEN tab + single chime + "waiting" title: the fully-settled, needs-
# attention signal. Deduped per event-type so two hooks firing for one event
# produce exactly one chime.
#
# The OPTIONAL first arg is a transcript path. When it is passed AND either a
# background agent is still running or CI is actively running, the main agent
# is free but background work continues — paint the tab BLUE, no chime, and
# return. Called with NO arg it paints green unconditionally.
#
# Do NOT rely on omitting the argument to mean "bypass the gate on purpose":
# call notify_user_attention_blocking below, which says so in its name. Absence
# of the argument otherwise only means the caller has no transcript to offer
# (e.g. the manual notify-waiting skill).
notify_user_attention() {
    local transcript="${1:-}"

    # Background-work gate: only when a transcript was supplied. Empty arg keeps
    # the legacy unconditional-green behavior untouched.
    if [ -n "$transcript" ] && { bg_agents_active "$transcript" || ci_is_active; }; then
        set_blue_bar
        return 0
    fi

    # Dedup scope for the chime. Kept as a fixed key so concurrent Stop /
    # Notification / AskUserQuestion hooks for one event chime only once.
    local event_type="attention"

    # Resolve the tty once and thread it to the helpers — find_user_tty walks
    # the PPID chain via ps, so we avoid repeating that on every hook fire.
    local target_tty
    target_tty=$(_resolve_target_tty)

    # Always set the green color and title even when the chime is deduped —
    # the visual state is idempotent, only the audible chime must be unique.
    _set_tab_rgb 0 255 0 "$target_tty"
    _set_tab_state green

    if _dedup_should_chime "$event_type" "$target_tty"; then
        _play_chime_sound
    fi

    local title
    title=$(_display_title)
    if [ -n "$title" ]; then
        printf '\033]0;%s\007' "$title" > "$target_tty" 2>/dev/null || true
    fi
}

# GREEN + chime for a prompt that BLOCKS the session: the permission guard's
# `ask`, an AskUserQuestion ping, and every Notification type that survives
# notification__sound.sh's suppression filter. All three fire for ONE logical
# user-facing moment (see the dedup note above), and nothing moves until the user
# answers, so a live Monitor, backgrounded Bash or CI watcher does not make the
# session any less stuck: "needs attention" always wins.
#
# THE single place that rule is written down. The three call sites used to encode
# it by simply omitting notify_user_attention's transcript argument, which made a
# deliberate override indistinguishable from a caller that just had no transcript
# — and one of the three was missed, so it repainted the tab BLUE over the GREEN
# the other two had just painted (the chime is deduped on a shared key; the tab
# paint is not).
notify_user_attention_blocking() {
    notify_user_attention
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
    _set_tab_rgb 0 0 255
    _set_tab_state blue
}

reset_tab_color() {
    local target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;*;default\a' > "$target_tty" 2>/dev/null || true
    # The tab now carries no state of ours, so drop the record — otherwise a
    # stale "green" would make the reset hook keep firing pointlessly.
    rm -f "$(_tab_state_file)" 2>/dev/null || true
}

# Echo the `Monitor` task id of every ci watcher belonging to session $1, one per
# line. The ci-watcher skill persists each watcher's task id at
# "${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_task_<SLOT>", and every SLOT starts with the
# session id, so this glob finds exactly this session's watchers and never
# another session's leftover sidecar.
#
# bg_agents_active uses it to EXCLUDE those monitors from generic background-work
# detection: a ci watcher is a long-lived Monitor that outlives the CI run it is
# reporting on, and ci_is_active is the check that knows when it is genuinely
# busy. Without the exclusion the tab would stay blue — and the chime silent —
# from the moment a watcher starts until it exits.
#
# Defined here, above its only caller, rather than beside the other ci_watch_*
# helpers further down: this file defines a private helper immediately before the
# function that consumes it.
_ci_watch_session_task_ids() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local f id
    # Same nullglob-free pattern as _ci_watch_session_state_files: the -f guard
    # drops both an unmatched literal glob and any non-regular file planted at a
    # predictable /tmp path (a FIFO there would block the read forever).
    for f in "${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_task_${session_id}"_*; do
        [ -f "$f" ] || continue
        # A task id is a short token; the byte cap stops a corrupt sidecar from
        # being slurped, and tr drops the trailing newline a writer may add.
        id=$(head -c 64 "$f" 2>/dev/null | tr -d '[:space:]')
        [ -n "$id" ] || continue
        printf '%s\n' "$id"
    done
    return 0
}

# True (0) only when the tail of the transcript at $1 shows a background-capable
# tool call whose result line has NOT landed yet — the one situation in which an
# activation marker can still be in flight, so the one situation worth re-reading
# the file for. The producers of an activation marker across the local corpus are
# `Agent` (launch), `SendMessage` (resume), `Monitor` (task launch) and `Bash`
# with run_in_background:true — nothing else. Reaching this helper already means
# the whole-file marker grep missed, so a tool call sitting in the tail with no
# marker anywhere is exactly the un-flushed-result case.
#
# Bash is matched on its run_in_background INPUT, never on the tool name: almost
# every turn ends with an ordinary foreground Bash call, so matching the name
# would put the bounded ~2s retry back on nearly every idle Stop.
# tail keeps the check O(1) however large the transcript grows; 3 lines gives a
# little slack for interleaved entries without inviting stale matches.
_bg_launch_in_flight() {
    tail -n 3 "$1" 2>/dev/null \
        | grep -qE '"name":"(Agent|SendMessage|Monitor)"|"run_in_background":[[:space:]]*true'
}

# Returns 0 (true) if >=1 background task is still running per the transcript
# at $1, else 1 (false). Fail-safe: empty/missing/unparseable transcript => false.
#
# "Background task" is every kind this harness can leave running past a Stop:
# an async `Agent`, a `Monitor` task, and a `Bash` call with run_in_background.
# All three terminate through the same <task-notification> task-id namespace;
# only their ACTIVATION markers differ (see the python block below).
#
# Detection is a per-task-id LAST-EVENT-WINS state machine resolved in TIMESTAMP
# order (not line order, not set subtraction). These event kinds move an id:
#   - launch:  toolUseResult.status == "async_launched"          -> active
#   - launch:  toolUseResult.taskId (Monitor)                    -> active
#   - launch:  toolUseResult.backgroundTaskId (backgrounded Bash) -> active
#   - resume:  a SendMessage toolUseResult whose message says the agent was
#              "resumed ... in the background"                   -> active
#   - stop:    a <task-notification> block with a terminal <status> -> terminated
#   - reap:    a blocking TaskOutput whose task.status is terminal -> terminated
# An id is active iff its LAST event was a launch or a resume. Set subtraction
# (active = launched - terminated) was wrong because termination was monotonic:
# a resumed agent emits NO new async_launched marker, so an id that had already
# stopped once could never leave the terminated set and the tab went green while
# the resumed agent was still running.
bg_agents_active() {
    local transcript="$1"
    # No usable transcript => treat as no background work.
    [ -n "$transcript" ] && [ -f "$transcript" ] || return 1

    # --- Cheap early-out: with no activation marker anywhere in the file no
    # background agent has ever been started, so skip the python scan entirely.
    #
    # The needle MUST be at least as permissive as the python detector it guards,
    # or the early-out could skip a case python would call active:
    #   - "async_launched" is the launch marker.
    #   - the python resume test needs "resumed" AND "in the background" in the
    #     SendMessage message, so matching the single word "resumed" is a strict
    #     superset of it. Matching the longer literal (e.g. "in the background
    #     with your message") would early-out to green on any resume phrased
    #     without that exact tail.
    #   - "timeoutMs" is the Monitor launch marker and "backgroundTaskId" the
    #     backgrounded-Bash one, mirroring exactly what python keys on below.
    #     Both are spelled out: the capital T in backgroundTaskId means a needle
    #     of "taskId" does NOT match it. "timeoutMs" rather than "taskId" is what
    #     keeps this cheap AND aligned — across the local corpus (4196
    #     transcripts) "timeoutMs" appears in Monitor results only (558), while a
    #     bare "taskId" also matches every TaskUpdate result (338 of them), which
    #     would spend a python scan on most ordinary turns.
    #
    # KNOWN COST, accepted: the needle is matched against the WHOLE file and
    # nothing ever un-matches it, so the first Monitor or backgrounded Bash of a
    # session makes every later Stop in that session take the python path too —
    # including turns long after that task finished. (Reading this very file, or
    # the tests, also plants the needles.) The probe below is therefore `grep -q`
    # rather than `grep -c`, which is what keeps the tripped state cheap.
    local marker_re='async_launched|resumed|timeoutMs|backgroundTaskId'

    # --- Flush/read race. Claude Code appends the "async_launched" line
    # milliseconds AFTER the assistant message that launched the agent, and the
    # Stop hook can read the file in between; a single instantaneous read then
    # misses a genuinely-running agent and wrongly paints the tab green. So on a
    # miss we re-read with a 1s poll interval — but ONLY while an activation line
    # can actually still be in flight (see _bg_launch_in_flight). A transcript
    # whose last lines are ordinary turns will never grow an activation line, so
    # the marker-free idle case settles on the FIRST read and waits 0s; before
    # this gate every idle turn of every session paid a flat ~2s.
    # Real-world frequency from the diagnostic log below: of 455 logged
    # evaluations exactly one needed a retry, and it was the first Stop hook
    # after two `Agent` launches.
    local marker=no          # "yes" once an activation marker is seen
    local retries=0          # extra reads beyond the first (0 == hit first try)
    local found=1            # 0 once the marker is seen, else 1
    local max_tries=3        # smallest bound that reliably closes the flush race
    local attempt=0
    while [ "$attempt" -lt "$max_tries" ]; do
        attempt=$((attempt + 1))
        # -q, NEVER -c: the decision here is a pure boolean, and -q stops reading
        # at the FIRST match while -c has to read every byte to finish counting.
        # Measured on the largest local transcript (71 MB): 47ms with -q against
        # 1809ms with -c. That whole-file count, not the python scan it guards,
        # was the real price of widening the needle above.
        if grep -qE "$marker_re" "$transcript" 2>/dev/null; then
            # Marker present => stop polling and fall through to the counting logic.
            marker=yes
            found=0
            break
        fi
        # Marker absent AND nothing can still be flushing => settle immediately.
        _bg_launch_in_flight "$transcript" || break
        # A launch/resume call is still awaiting its result line: poll again
        # after a 1s interval (bounded to max_tries reads == <=2s total).
        if [ "$attempt" -lt "$max_tries" ]; then
            sleep 1
        fi
    done
    retries=$((attempt - 1))

    # Counts fed to the diagnostic log below; default to the "no work" case that
    # holds when the marker never appeared after the bounded retries.
    local n_launched=0 n_terminated=0 n_resumed=0 n_active=0

    # Marker never showed up even after the retries => genuinely no background
    # agent. Log the miss and return false (green) without spawning python.
    if [ "$found" -ne 0 ]; then
        _bg_agents_log "$marker" "$retries" 0 0 0 0 0 "green(idle)"
        return 1
    fi

    # Monitor task ids of this session's ci watchers — handed to python so it can
    # leave them to ci_is_active (see CI_WATCH_TASK_IDS there).
    local ci_task_ids n_ci_skipped
    ci_task_ids=$(_ci_watch_session_task_ids "${CLAUDE_CODE_SESSION_ID:-}")
    # Logged below so a BLUE caused by a MISSING exclusion (a reaped or
    # overwritten ci_watch_task_<SLOT> sidecar) is told apart from a BLUE caused
    # by real background work. Without it both look like a plain blue(active).
    n_ci_skipped=$(printf '%s' "$ci_task_ids" | grep -c '[^[:space:]]' || true)

    # Count active background tasks via the transcript scan (fail-open to 0).
    # Python prints four space-separated counts: launched terminated resumed active.
    local count
    count=$(python3 - "$transcript" "$ci_task_ids" <<'PYEOF' 2>/dev/null
import sys, json, re, os

transcript_path = sys.argv[1]
debug = os.environ.get("CLAUDE_DEBUG_NOTIFY") == "1"

# Monitor task ids belonging to THIS session's ci watchers, newline-separated on
# argv[2] (see _ci_watch_session_task_ids). They are deliberately NOT treated as
# generic background work — ci_is_active owns that decision.
CI_WATCH_TASK_IDS = {t for t in sys.argv[2].split("\n") if t}

# Any of these statuses means the task is no longer running. An unrecognized
# status never clears an id, so a missing terminal status pins the tab blue and
# silences the chime forever — which is why "failed", "killed" and "stopped"
# (what TaskStop emits) must be here alongside "completed".
# This is exactly the set OBSERVED across the local corpus, counting every
# <task-notification> block in 4196 transcripts (duplicate copies of one
# notification included): completed 10638, failed 2337, killed 137, stopped 39.
# TaskOutput's task.status carries only completed / failed / running there — no
# fourth spelling. "stopped" is the wording TaskStop uses on a Monitor /
# backgrounded-Bash task ("Task ... was stopped by main session"); "killed" is
# the agent-side wording.
# Nothing else is listed on purpose: guessing extra terminal names is the
# false-GREEN direction (a status invented here could clear a live task).
TERMINAL_STATUSES = {"completed", "failed", "killed", "stopped"}

# agent IDs that were async-launched (toolUseResult.agentId)
launched = set()
# agent IDs that were RESUMED in the background via SendMessage. A resume makes a
# previously-stopped agent live again WITHOUT emitting a new async_launched
# marker, so it must be tracked as its own activation event.
resumed = set()
# task-ids that reached a terminal status (parsed from <task-notification> blocks).
# These are the SAME identifier namespace as agentId — both sides use the
# 17-char "a"-prefixed hex string.
terminated = set()
# Collected (sort_key, task_id, "active"|"terminated") events, resolved AFTER the
# whole file is read and ordered by the entry's own timestamp — not by line order.
#
# NEITHER raw ordering identifies an event on its own, because ONE logical
# task-notification is recorded TWICE: a queue-operation copy and the delivered
# copy, byte-identical text, at two DIFFERENT timestamps (1394 duplicate
# emissions out of 3277 notification blocks measured across that corpus, spread from
# 12ms to over two minutes apart).
#   - line order is wrong because a queue-operation entry is written at the
#     position where it was QUEUED, which can sit many lines away from the event
#     it describes.
#   - timestamp order is wrong because the SECOND copy can post-date a
#     SendMessage resume issued in the same turn, so a stale terminal
#     notification overrides the resume and the tab goes green while the resumed
#     agent keeps working (real case: 4341261e, agent ac8f6d806ba8113a1, notified
#     at 09:51:01.159Z, resumed at 09:51:03.889Z, duplicate copy of the SAME
#     notification at 09:51:03.983Z, actual finish 09:56:34.201Z).
# Deduping the copies by <tool-use-id> and keeping the EARLIEST recording is what
# makes the sort key identify the event instead of one arbitrary recording of it;
# only then does last-event-wins mean anything.
events = []
# Deduped notifications: dedupe id -> (earliest sort_key, task_id). Folded into
# `events` once the file has been read.
notif_events = {}

# SendMessage's result message when it (re)starts a stopped agent. All three
# phrasings observed in the local corpus are covered (89 / 36 / 10 occurrences):
#   Agent "<id>" had no active task; resumed from transcript in the background...
#   Agent "<id>" was stopped (failed); resumed it in the background with your...
#   Agent "<id>" was stopped (completed); resumed it in the background with your...
# The match deliberately keys on "resumed" + "in the background" rather than any
# full phrase, so a fourth wording cannot silently stop being detected.
RESUME_ID_RE = re.compile(r'Agent "([^"]+)"')
# Only trust an id in the notification namespace ("a" + 16 hex). SendMessage also
# accepts an agent NAME, and echoing a name into the active set could pin the tab
# blue forever (no notification would ever clear it), permanently silencing the
# attention chime. Ignoring those keeps the failure direction safe.
# fullmatch for the same reason as BG_TASK_ID_RE below: RESUME_ID_RE's [^"]+
# capture can contain a newline, and "$" would let one through.
AGENT_ID_RE = re.compile(r"a[0-9a-f]{16}")

# Monitor and backgrounded-Bash tasks use their OWN id namespace: "b" + 8
# lowercase alphanumerics (e.g. bnk163hnc, braju6wbj). All 558 Monitor and 622
# backgrounded-Bash launch results in the local corpus (557 / 619 distinct ids)
# have this shape, and no TaskUpdate ordinal ("1", "2", ...) does — so it is the
# shape guard that keeps a todo-list update from being mistaken for a running
# background task.
#
# fullmatch, never match(...$): "$" ALSO matches just before a trailing newline,
# so re.match would accept "braju6wbj\n" as a valid id. Nothing could then ever
# clear it — the <task-id> in the terminating <task-notification> carries no
# newline and would not compare equal — so the tab would stay blue and the chime
# dead for the rest of the session.
BG_TASK_ID_RE = re.compile(r"b[0-9a-z]{8}")

# Match <task-notification> blocks and pull out their <task-id> + <status>.
# DOTALL so .*? crosses the literal "\n" inside the JSON-encoded string.
TASK_NOTIF_RE = re.compile(
    r"<task-notification>(.*?)</task-notification>", re.DOTALL
)
TASK_ID_RE = re.compile(r"<task-id>\s*([^<\s]+)\s*</task-id>")
STATUS_RE = re.compile(r"<status>\s*([^<\s]+)\s*</status>")
# Identifies WHICH run of an agent a notification belongs to: the launching Task
# call's id, or the resuming SendMessage's id for a resumed run. Two copies of one
# notification share it; two runs of the same agent never do — so it is the right
# key for collapsing the duplicate copies without collapsing distinct runs.
TOOL_USE_ID_RE = re.compile(r"<tool-use-id>\s*([^<\s]+)\s*</tool-use-id>")

def scan_text_for_terminations(text, key):
    if not text or "<task-notification>" not in text:
        return
    for block in TASK_NOTIF_RE.findall(text):
        status_match = STATUS_RE.search(block)
        if not status_match:
            continue
        status = status_match.group(1).strip().lower()
        if status not in TERMINAL_STATUSES:
            continue
        task_id_match = TASK_ID_RE.search(block)
        if not task_id_match:
            continue
        task_id = task_id_match.group(1).strip()
        terminated.add(task_id)
        # Collapse the duplicate copies of this one notification and keep the
        # EARLIEST recording of it (see the note on `events`). 159 of 3277 real
        # blocks carry no <tool-use-id>; those fall back to the full block text,
        # which is byte-identical between copies and includes the agent's own
        # <result>, so distinct runs stay distinct.
        tuid_match = TOOL_USE_ID_RE.search(block)
        dedupe_id = tuid_match.group(1) if tuid_match else block
        prev = notif_events.get(dedupe_id)
        if prev is None or key < prev[0]:
            notif_events[dedupe_id] = (key, task_id)

try:
    with open(transcript_path, "r") as f:
        # Timestamps are uniform ISO-8601 UTC ("...Z"), so they sort correctly as
        # plain strings. Entries with no timestamp of their own inherit the last
        # one seen — their nearest preceding sibling is the best clock available,
        # and inheriting "" instead would sort them before every timestamped
        # event, letting an undated termination outrank a real launch. The line
        # number breaks ties, keeping the order total and stable.
        # Defensive: the local corpus has 14749 undated entries but none of them
        # carries a launch or a notification, so this only matters if that ever
        # changes — which is exactly why the direction is pinned by a test.
        last_ts = ""
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = entry.get("timestamp")
            if isinstance(ts, str) and ts:
                last_ts = ts
            key = (last_ts, line_no)

            # --- Launches: toolUseResult.status == "async_launched" carries agentId
            tool_result = entry.get("toolUseResult", {})
            if isinstance(tool_result, dict) and tool_result.get("status") == "async_launched":
                agent_id = tool_result.get("agentId") or entry.get("agentId")
                if agent_id:
                    launched.add(agent_id)
                    events.append((key, agent_id, "active"))

            # --- Monitor launches: the Monitor tool's result is
            # {"taskId": ..., "timeoutMs": ..., "persistent": ...}. It carries NO
            # "async_launched", so before this the tab went green and chimed the
            # moment the launching turn ended, with the monitor still streaming.
            #
            # It is keyed on "timeoutMs", NOT on a bare "taskId": the TaskUpdate
            # (todo-list) tool ALSO returns a top-level "taskId", an ordinal like
            # "1" that no <task-notification> can ever terminate. Treating one of
            # those as background work would pin the tab blue and kill the chime
            # for the rest of the session. Across the local corpus (4196
            # transcripts) "timeoutMs" is Monitor-only (558 results, every one of
            # them with a BG_TASK_ID_RE-shaped id), while "taskId" alone also
            # matches 338 TaskUpdate results, none of which are that shape. The
            # id regex is the second, independent guard on the same distinction.
            #
            # EXCEPTION — this session's own ci-watcher monitors. A ci-watcher is
            # a persistent Monitor that stays alive from launch until the PR's
            # post-merge CI resolves, so counting it here would pin the tab blue
            # for the watcher's whole life and swallow the very chime that says
            # "CI passed — come merge". ci_is_active already models it correctly
            # (blue only while the state is running/merging), so those ids are
            # skipped and left entirely to that check.
            #
            # ACCEPTED LIMITATION, not an oversight: the exception is keyed on
            # ci-watcher ids only, so ANY OTHER never-terminating Monitor (a
            # `tail -F` log follower, an unbounded poll loop) keeps the tab blue
            # and the Stop chime silent for the rest of the session. Measured on
            # the local corpus, 366 of 558 Monitor launches never reach a terminal
            # event in-file, and the persistent flag does NOT separate them (169
            # persistent vs 197 non-persistent), so "skip persistent Monitors"
            # would fix under half of them while re-opening the false-GREEN hole
            # this detector exists to close. Blocking prompts still chime
            # unconditionally (see notify_user_attention_blocking), so the user is
            # never fully deaf. Narrowing this needs a liveness signal the
            # transcript does not currently carry.
            #
            # A backgrounded Bash call (run_in_background:true) returns
            # "backgroundTaskId" instead. Same story: no "async_launched", so it
            # too was invisible to this detector. It gets no exception — every
            # backgrounded shell command is work the user is waiting on.
            # A FOREGROUND Bash call that hit its timeout and was moved to the
            # background lands here too, but only once its result carries
            # backgroundTaskId: _bg_launch_in_flight keys on the run_in_background
            # INPUT, which such a call never had, so a Stop inside its pre-flush
            # window settles GREEN once and corrects itself on the next turn.
            if isinstance(tool_result, dict):
                monitor_id = tool_result.get("taskId")
                if "timeoutMs" in tool_result and isinstance(monitor_id, str) \
                        and BG_TASK_ID_RE.fullmatch(monitor_id) \
                        and monitor_id not in CI_WATCH_TASK_IDS:
                    launched.add(monitor_id)
                    events.append((key, monitor_id, "active"))
                bash_id = tool_result.get("backgroundTaskId")
                if isinstance(bash_id, str) and BG_TASK_ID_RE.fullmatch(bash_id):
                    launched.add(bash_id)
                    events.append((key, bash_id, "active"))

            # --- Resumes: a SendMessage result that restarted a stopped agent in
            # the background. This is an activation event with no async_launched
            # marker of its own, so without it a resumed agent stays wrongly
            # pinned as terminated by its earlier stop notification.
            if isinstance(tool_result, dict) and tool_result.get("success") is not False:
                msg = tool_result.get("message")
                if isinstance(msg, str) and "resumed" in msg \
                        and "in the background" in msg:
                    id_match = RESUME_ID_RE.search(msg)
                    if id_match and AGENT_ID_RE.fullmatch(id_match.group(1)):
                        agent_id = id_match.group(1)
                        resumed.add(agent_id)
                        events.append((key, agent_id, "active"))

            # --- Terminations via TaskOutput: a blocking TaskOutput reaps the
            # agent itself and NO <task-notification> is ever emitted, so this is
            # the only record that the agent stopped. Missing it leaves the id
            # active forever, pinning the tab blue and silencing the chime.
            # Only the terminal direction is honored: a "running" reading is
            # already covered by the launch/resume event and trusting it could
            # revive an agent that has since stopped.
            if isinstance(tool_result, dict):
                task = tool_result.get("task")
                if isinstance(task, dict):
                    task_id = task.get("task_id")
                    task_status = task.get("status")
                    if task_id and isinstance(task_status, str) \
                            and task_status.strip().lower() in TERMINAL_STATUSES:
                        terminated.add(task_id)
                        events.append((key, task_id, "terminated"))

            # --- Terminations: <task-notification> blocks appear in multiple forms.
            # Form 1: queue-operation entry, top-level "content" is a plain string
            top_content = entry.get("content")
            if isinstance(top_content, str):
                scan_text_for_terminations(top_content, key)

            # Form 2: user/assistant message.content as plain string or block list
            message = entry.get("message", {})
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    scan_text_for_terminations(content, key)
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        text = block.get("text", "") or ""
                        scan_text_for_terminations(text, key)

    # Fold the deduped notifications in: one event per notification, carrying the
    # earliest timestamp at which that notification was recorded.
    for ev_key, task_id in notif_events.values():
        events.append((ev_key, task_id, "terminated"))

    # Resolve last-event-wins per task-id in chronological order.
    # On an exact key tie (one line recording both an activation and a
    # termination) "terminated" is sorted last so it wins: a spurious green
    # chimes once too early, a spurious blue silences the terminal for the whole
    # session, so ambiguity resolves toward green.
    state = {}
    for _key, task_id, kind in sorted(
        events, key=lambda ev: (ev[0], ev[2] == "terminated")
    ):
        state[task_id] = kind

    # Active = ids whose LAST chronological event was an activation.
    active = {task_id for task_id, st in state.items() if st == "active"}
    if debug:
        print(
            f"[bg_agents_active] launched={sorted(launched)} "
            f"resumed={sorted(resumed)} "
            f"terminated={sorted(terminated)} active={sorted(active)}",
            file=sys.stderr,
        )
    # Emit "launched terminated resumed active" so the caller can both decide
    # (active) and log the component counts on one line.
    print(len(launched), len(terminated), len(resumed), len(active))
except Exception as e:
    if debug:
        print(f"[bg_agents_active] error: {e!r}", file=sys.stderr)
    # On any error, assume 0 active so sound plays
    print(0, 0, 0, 0)
PYEOF
    )

    # Split the "launched terminated resumed active" line; blanks fail-open to 0.
    # That fail-open also covers a missing or broken python3, which then decides
    # GREEN + chime. Deliberate: a missing interpreter is a PERMANENT condition,
    # so failing blue would silence the chime on every turn of every session
    # forever, while failing green only mis-chimes during the rare windows when a
    # background agent happens to be running.
    read -r n_launched n_terminated n_resumed n_active <<< "$count"
    n_launched=${n_launched:-0}
    n_terminated=${n_terminated:-0}
    n_resumed=${n_resumed:-0}
    n_active=${n_active:-0}

    # Decide: blue (background work) iff we parsed a positive active count.
    local decision="green(idle)"
    [ "$n_active" -gt 0 ] 2>/dev/null && decision="blue(active)"

    # --- Diagnostic logging (intentional; kept to confirm the flush/read race
    # in the wild). One appended line per evaluation; never touches the stdout
    # or exit code the callers rely on.
    _bg_agents_log "$marker" "$retries" "$n_ci_skipped" "$n_launched" \
        "$n_terminated" "$n_resumed" "$n_active" "$decision"

    # True iff we parsed a positive active count (final statement == return code).
    [ "$n_active" -gt 0 ] 2>/dev/null
}

# Diagnostic helper: append one line recording a single bg_agents_active
# evaluation (timestamp, whether the activation marker was seen, retry count, how
# many ci-watcher ids were excluded, and the launched/terminated/resumed/active/
# decision breakdown). ci_skipped is what tells a legitimate blue apart from one
# caused by a ci_watch_task_<SLOT> sidecar that went missing while its watcher was
# still alive. Best-effort — any failure is swallowed so it can never affect the
# caller's return value or stdout.
_bg_agents_log() {
    local marker="$1" retries="$2" ci_skipped="$3" launched="$4" terminated="$5"
    local resumed="$6" active="$7" decision="$8"
    local logfile="${CLAUDE_NOTIFY_TMP_DIR}/notify_bgdetect_${CLAUDE_CODE_SESSION_ID:-nosession}.log"
    printf '%s marker=%s retries=%s ci_skipped=%s launched=%s terminated=%s resumed=%s active=%s decision=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$marker" "$retries" "$ci_skipped" \
        "$launched" "$terminated" "$resumed" "$active" "$decision" \
        >> "$logfile" 2>/dev/null || true
}

# --- CI watcher slots -------------------------------------------------------
# One session runs one watcher PER BRANCH, and every /tmp file of a watcher is
# keyed on that watcher's SLOT:
#   SLOT = "<session id>_<branch slug>-<identity hash>"
# The identity hash is the first 10 hex chars of sha256("<owner>/<repo>#<branch>").
# It, not the readable branch slug, is what makes the slot unique — folding in
# owner/repo is what stops two worktrees of DIFFERENT repos that share a branch
# name from sharing a slot.

# The readable branch slug: every BYTE outside [A-Za-z0-9._-] becomes "_",
# capped at 40 bytes. LC_ALL=C forces tr and cut into byte mode so this matches
# ci_watch.py's sanitize_branch() exactly — a codepoint-vs-byte disagreement on
# a non-ASCII branch name would desync the two languages' slots.
_ci_slug() {
    # The $( ) strips cut's line terminator, so the slug carries no trailing
    # newline for a caller that does not wrap it in a command substitution of
    # its own. tr has already turned any real newline into "_".
    printf '%s' "$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-40)"
}

# Build a full SLOT. Args: <session id> <owner/repo> <branch>.
# THE single bash implementation: skills/ci-watcher/SKILL.md sources this file
# and calls this function. Do not re-inline the pipeline anywhere.
_ci_slot() {
    local session_id="$1" name_with_owner="$2" branch="$3"
    local identity_hash
    identity_hash=$(printf '%s' "${name_with_owner}#${branch}" \
        | shasum -a 256 | cut -c1-10)
    # Validate rather than trust: shasum is a perl script, not a coreutils
    # binary, and is absent on many minimal images. An empty hash would build a
    # slot no watcher ever owns, and every liveness check, stop and launch would
    # then target files that do not exist — silently.
    case "$identity_hash" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *)
            echo "Error: could not compute the ci watcher identity hash (is shasum installed?)." >&2
            return 1
            ;;
    esac
    printf '%s_%s-%s' "$session_id" "$(_ci_slug "$branch")" "$identity_hash"
}

# Echo the path of every EXISTING ci_watch state file belonging to session $1,
# one per line — i.e. one line per watcher the session is currently running.
# THE single discovery implementation: ci_is_active below and status_line.sh
# both call this, so "which watchers does this session have" is defined once.
_ci_watch_session_state_files() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local f
    # `nullglob` is deliberately NOT set (it is global shell state and this file
    # is sourced into other scripts): with no match bash leaves the pattern
    # literal, so the -e guard is what drops it.
    for f in "${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_state_${session_id}"_*; do
        # REGULAR files only, never -e. These paths are predictable and live in
        # a shared /tmp, so a FIFO planted at one of them would block the `cat`
        # of every consumer — the 1s status-line poll and ci_is_active inside
        # the Stop hook — forever. -f also drops an unmatched literal glob.
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
    done
    return 0
}

# Return 0 (CI actively running) when ANY watcher of this session satisfies ALL
# of:
#   (1) its state value is "running" or "merging",
#   (2) its state carries no ":monitor-detached@" marker,
#   (3) its OWN lockfile names a live ci_watch PID.
# Returns 1 (non-active) when the session has no state file at all, or every
# watcher it has is dead (so a stale "running" from a crashed watcher can never
# pin the tab blue), mute, or in a terminal state.
#
# There is deliberately NO branch-match test against the cwd: a session can now
# watch several branches at once, and any of them still running is "background
# work in progress" for the tab-colour signal, whatever the shell's cwd is on.
ci_is_active() {
    local session_id="${CLAUDE_CODE_SESSION_ID:-}"
    [ -n "$session_id" ] || return 1

    local state_file raw state_only slot lock_file watcher_pid
    while IFS= read -r state_file; do
        [ -n "$state_file" ] || continue
        # The atomically-written "<branch>:<state>" line. cat covers the
        # missing-file case; the empty guard covers missing and empty alike.
        raw=$(cat "$state_file" 2>/dev/null || true)
        [ -n "$raw" ] || continue
        # No colon means no branch prefix, so the line is not a usable state.
        case "$raw" in
            *:*) state_only="${raw#*:}" ;;
            *) continue ;;
        esac

        # ci_watch.py appends ":monitor-detached@<epoch>" once its stdout writes
        # start failing. The process lives on, but nothing it finds will ever be
        # reported, so it is NOT "background work in progress": folding it into
        # the active bucket would paint the tab blue and swallow the chime while
        # the CI result silently goes nowhere. status_line.sh renders the
        # distinct "ci notifications lost" label for the same marker.
        case "$state_only" in
            *:monitor-detached@*) continue ;;
        esac

        case "$state_only" in
            running|merging) ;;
            *) continue ;;
        esac

        # Liveness is per-slot: read the PID from THIS watcher's lockfile,
        # kill -0 it, and confirm its args mention ci_watch (so a recycled PID
        # owned by an unrelated process can't pass).
        slot="${state_file##*/ci_watch_state_}"
        lock_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_lock_${slot}"
        # First line only, and a regular file only: acquire_lock writes the pid
        # at offset 0 and truncates afterwards, so a longer predecessor's tail
        # can briefly follow it.
        [ -f "$lock_file" ] || continue
        watcher_pid=$(head -n 1 "$lock_file" 2>/dev/null || true)
        if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null \
           && ps -p "$watcher_pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
            return 0
        fi
    done < <(_ci_watch_session_state_files "$session_id")
    return 1
}
