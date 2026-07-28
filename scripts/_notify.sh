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
_DEDUP_WINDOW_SECONDS=3
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

# Play the attention chime (Glass.aiff) detached, if afplay is available.
_play_chime_sound() {
    if command -v afplay >/dev/null 2>&1; then
        afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
        disown
    fi
}

# GREEN tab + single chime + "waiting" title: the fully-settled, needs-
# attention signal. Deduped per event-type so two hooks firing for one event
# produce exactly one chime.
#
# The OPTIONAL first arg is a transcript path. When it is passed AND either a
# background agent is still running or CI is actively running, the main agent
# is free but background work continues — paint the tab BLUE, no chime, and
# return. Called with NO arg (e.g. the manual notify-waiting skill) it behaves
# exactly as before: unconditional green + chime.
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

    if _dedup_should_chime "$event_type" "$target_tty"; then
        _play_chime_sound
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-repo")
    printf '\033]0;%s\007' "$branch" > "$target_tty" 2>/dev/null || true
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
}

reset_tab_color() {
    local target_tty
    target_tty=$(_resolve_target_tty)
    printf '\033]6;1;bg;*;default\a' > "$target_tty" 2>/dev/null || true
}

# True (0) only when the tail of the transcript at $1 shows a background-capable
# tool call whose result line has NOT landed yet — the one situation in which an
# activation marker can still be in flight, so the one situation worth re-reading
# the file for. `Agent` is the launch tool and `SendMessage` the resume tool (the
# only two producers of an activation marker across the local corpus: 1314 and
# 137 occurrences respectively, nothing else). Reaching this helper already means
# the whole-file marker grep missed, so a tool call sitting in the tail with no
# marker anywhere is exactly the un-flushed-result case.
# tail keeps the check O(1) however large the transcript grows; 3 lines gives a
# little slack for interleaved entries without inviting stale matches.
_bg_launch_in_flight() {
    tail -n 3 "$1" 2>/dev/null | grep -qE '"name":"(Agent|SendMessage)"'
}

# Returns 0 (true) if >=1 background agent is still running per the transcript
# at $1, else 1 (false). Fail-safe: empty/missing/unparseable transcript => false.
#
# Detection is a per-task-id LAST-EVENT-WINS state machine resolved in TIMESTAMP
# order (not line order, not set subtraction). Four event kinds move an id:
#   - launch:  toolUseResult.status == "async_launched"          -> active
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
    local marker_re='async_launched|resumed'

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
    local grep_count=0       # raw count of launch+resume markers from the last read
    local retries=0          # extra reads beyond the first (0 == hit first try)
    local found=1            # 0 once the marker is seen, else 1
    local max_tries=3        # smallest bound that reliably closes the flush race
    local attempt=0
    while [ "$attempt" -lt "$max_tries" ]; do
        attempt=$((attempt + 1))
        grep_count=$(grep -cE "$marker_re" "$transcript" 2>/dev/null)
        grep_count=${grep_count:-0}
        # Marker present => stop polling and fall through to the counting logic.
        if [ "$grep_count" -gt 0 ] 2>/dev/null; then
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
        _bg_agents_log "$grep_count" "$retries" 0 0 0 0 "green(idle)"
        return 1
    fi

    # Count active background agents via the transcript scan (fail-open to 0).
    # Python prints four space-separated counts: launched terminated resumed active.
    local count
    count=$(python3 - "$transcript" <<'PYEOF' 2>/dev/null
import sys, json, re, os

transcript_path = sys.argv[1]
debug = os.environ.get("CLAUDE_DEBUG_NOTIFY") == "1"

# Any of these statuses means the agent is no longer running. An unrecognized
# status never clears an id, so a missing terminal status pins the tab blue and
# silences the chime forever — which is why "failed" and "killed" (what TaskStop
# emits) must be here alongside "completed".
# This is exactly the set OBSERVED across the local corpus (~2.8k transcripts):
# completed 2877, failed 265, killed 18 in <task-notification>, and
# completed / running / in_progress / pending in TaskOutput's task.status.
# Nothing else is listed on purpose: guessing extra terminal names is the
# false-GREEN direction (a status invented here could clear a live agent).
TERMINAL_STATUSES = {"completed", "failed", "killed"}

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
AGENT_ID_RE = re.compile(r"^a[0-9a-f]{16}$")

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

            # --- Resumes: a SendMessage result that restarted a stopped agent in
            # the background. This is an activation event with no async_launched
            # marker of its own, so without it a resumed agent stays wrongly
            # pinned as terminated by its earlier stop notification.
            if isinstance(tool_result, dict) and tool_result.get("success") is not False:
                msg = tool_result.get("message")
                if isinstance(msg, str) and "resumed" in msg \
                        and "in the background" in msg:
                    id_match = RESUME_ID_RE.search(msg)
                    if id_match and AGENT_ID_RE.match(id_match.group(1)):
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
    _bg_agents_log "$grep_count" "$retries" "$n_launched" "$n_terminated" \
        "$n_resumed" "$n_active" "$decision"

    # True iff we parsed a positive active count (final statement == return code).
    [ "$n_active" -gt 0 ] 2>/dev/null
}

# Diagnostic helper: append one line recording a single bg_agents_active
# evaluation (timestamp, raw launch+resume marker count, retry count, and the
# launched/terminated/resumed/active/decision breakdown). Best-effort — any
# failure is swallowed so it can never affect the caller's return value or stdout.
_bg_agents_log() {
    local grep_count="$1" retries="$2" launched="$3" terminated="$4"
    local resumed="$5" active="$6" decision="$7"
    local logfile="${CLAUDE_NOTIFY_TMP_DIR}/notify_bgdetect_${CLAUDE_CODE_SESSION_ID:-nosession}.log"
    printf '%s grep_count=%s retries=%s launched=%s terminated=%s resumed=%s active=%s decision=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$grep_count" "$retries" \
        "$launched" "$terminated" "$resumed" "$active" "$decision" \
        >> "$logfile" 2>/dev/null || true
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
