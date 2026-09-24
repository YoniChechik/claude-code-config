#!/usr/bin/env bash
# ============================================================================
# stop__wakeup_status.sh
# ----------------------------------------------------------------------------
# Purpose:
#   Stop hook that mirrors the Stop hook input's `session_crons` array into a
#   per-session sidecar file, so status_line.sh (polled ~1s by Claude Code's
#   statusLine config) can show a "wakeup armed" indicator without doing any
#   cron computation itself on that hot path.
#
# What populates session_crons:
#   Per the official hooks reference (docs/en/hooks#stop-input, verified
#   2026-09-24): "Each entry in session_crons describes one session-scoped
#   scheduled wakeup, sourced from CronCreate, ScheduleWakeup, and /loop."
#   ScheduleWakeup — the tool a self-paced `/loop` uses to arm/clear its next
#   iteration — is explicitly one of the three sources, confirmed again on the
#   ScheduleWakeup tool's own doc entry: "The pending wakeup appears in
#   session_crons in Stop hook input." So this hook covers /loop dynamic
#   pacing, not just explicit CronCreate tasks.
#
# Entry shape: {id, schedule (5-field cron expression), recurring (bool),
#   prompt}. There is no explicit next-fire-time field — for a one-shot entry
#   (recurring: false) the schedule's minute/hour/day/month directly encode
#   the single fire time; for a recurring entry it's a real cron pattern that
#   needs matching forward from now.
#
# Mechanism:
#   ASYNC on purpose (unlike stop__session_name_reminder.sh, which must run
#   synchronously to inject additionalContext for the model). This hook never
#   emits hookSpecificOutput -- it only writes/clears a sidecar file, a pure
#   side effect nothing in the current turn depends on. The status line reads
#   that file on its own ~1s poll regardless of exactly when this hook's
#   write lands, so blocking the Stop event on it would only add latency for
#   no correctness benefit.
#
# Cadence:
#   Runs on every Stop, same as the session-name reminder. The common case
#   (`session_crons` empty) is a cheap jq call and an `rm -f`; only a session
#   with an actually-armed wakeup pays for the python cron computation below.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr. A hook that
#   fails loudly is worse than an indicator that fails to update.
# ============================================================================

# Strict mode WITHOUT -e, same rationale as stop__session_name_reminder.sh: a
# missing sidecar dir or a failed write must degrade to "exit 0 silently",
# never abort the hook with an error.
set -uo pipefail

# ----------------------------------------------------------------------------
# Step 1: Drain stdin once so Claude Code never blocks waiting on us.
# ----------------------------------------------------------------------------
input=$(cat)

# ----------------------------------------------------------------------------
# Step 2: Pull the session id off the payload. Without it there is no
#   per-session sidecar to key, so exit silently.
# ----------------------------------------------------------------------------
session_id=$(jq -r '.session_id // empty' <<< "$input" 2>/dev/null)
if [ -z "$session_id" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 3: Same path-safety gate as stop__session_name_reminder.sh -- the
#   session id goes straight into a filesystem path, so it must be a single
#   safe path component.
# ----------------------------------------------------------------------------
if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 4: Shared helpers -- _wakeup_next_path (the sidecar path contract) and
#   _sanitize_and_cap (the label sanitize-and-cap contract), both defined
#   exactly once in _notify.sh.
# ----------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

sidecar=$(_wakeup_next_path "$session_id" 2>/dev/null) || exit 0
if [ -z "$sidecar" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 5: Refuse to touch the path if something that is not a regular file is
#   already sitting there -- same directory/FIFO hazard called out in
#   stop__session_name_reminder.sh.
# ----------------------------------------------------------------------------
if [ -e "$sidecar" ] && [ ! -f "$sidecar" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 6: Pull out session_crons. `(.session_crons // []) | select(length>0)`
#   collapses every "nothing scheduled" shape (key absent, null, or `[]`) to
#   empty output, and malformed JSON input makes jq itself fail, which also
#   leaves $entries empty via the `2>/dev/null` -- so "no entries" and
#   "unparseable input" take the exact same clearing path below.
# ----------------------------------------------------------------------------
entries=$(jq -c '(.session_crons // []) | select(length>0)' <<< "$input" 2>/dev/null)

# ----------------------------------------------------------------------------
# Step 7: The atomic state writer -- mktemp in the same directory, write,
#   `mv -f` over the target, so a concurrent status_line.sh poll never
#   observes a half-written file. Mirrors _write_state in
#   stop__session_name_reminder.sh and `write` in rename_session.sh.
# ----------------------------------------------------------------------------
_write_sidecar() {
    local tmp
    tmp="$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/wakeup_next_XXXXXX" 2>/dev/null)" || return 1
    if ! printf '%s\n%s' "$1" "$2" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$sidecar" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 8: Nothing scheduled -- clear the sidecar. This IS the "until it
#   finishes" behavior: once session_crons goes back to empty, the indicator
#   must disappear rather than keep showing a stale time.
# ----------------------------------------------------------------------------
if [ -z "$entries" ]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 9: Compute the earliest upcoming fire time across all entries.
#
#   One-shot entries (recurring: false) resolve in O(1): per the docs, their
#   schedule's minute/hour/day/month directly encode a single fire time, so
#   we just construct that datetime (trying this year then next, to handle a
#   schedule landing right at a year boundary) rather than searching for it.
#
#   Recurring entries use a bounded brute-force minute-by-minute search,
#   capped at 8 days. That bound is always sufficient for any still-live
#   entry: per the scheduled-tasks docs, "Recurring tasks automatically
#   expire 7 days after creation," so a recurring entry that hasn't fired
#   again within 8 days of now has already expired and Claude Code would not
#   be reporting it. `WAKEUP_STATUS_NOW_EPOCH` overrides "now" -- test-only,
#   for deterministic cron-matching assertions.
#
#   A single malformed entry (unparseable schedule, out-of-range field, wrong
#   field count) is skipped rather than aborting the whole computation, since
#   this reaches us as reported hook data, not code we trust to be well
#   formed forever.
# ----------------------------------------------------------------------------
result=$(printf '%s' "$entries" | python3 -c '
import datetime
import json
import os
import sys


def parse_field(spec, lo, hi):
    """Return the set of ints one cron field matches, honoring *, N, A-B,
    and (A-B|*)/STEP -- the syntax the scheduled-tasks docs say is
    supported. Raises ValueError on anything else or an out-of-range value.
    """
    if spec == "*":
        return set(range(lo, hi + 1))
    vals = set()
    for token in spec.split(","):
        base, step = token, 1
        if "/" in token:
            base, step_s = token.split("/", 1)
            step = int(step_s)
            if step <= 0:
                raise ValueError("non-positive step")
        if base == "*":
            start, end = lo, hi
        elif "-" in base:
            a, b = base.split("-", 1)
            start, end = int(a), int(b)
        else:
            start = end = int(base)
        if start < lo or end > hi or start > end:
            raise ValueError("field value out of range")
        vals.update(range(start, end + 1, step))
    return vals


def next_fire(schedule, recurring, now):
    parts = schedule.split()
    if len(parts) != 5:
        return None
    minutes = parse_field(parts[0], 0, 59)
    hours = parse_field(parts[1], 0, 23)
    doms = parse_field(parts[2], 1, 31)
    months = parse_field(parts[3], 1, 12)
    dows_raw = parse_field(parts[4], 0, 7)
    if not (minutes and hours and doms and months and dows_raw):
        return None
    dows = {d % 7 for d in dows_raw}  # fold 7 (Sunday) onto 0
    dom_wild = parts[2] == "*"
    dow_wild = parts[4] == "*"

    if not recurring:
        # One-shot: the schedule encodes a single fire time directly.
        minute, hour, day, month = min(minutes), min(hours), min(doms), min(months)
        for year in (now.year, now.year + 1):
            try:
                candidate = datetime.datetime(year, month, day, hour, minute)
            except ValueError:
                continue
            if candidate > now:
                return candidate
        return None

    # Recurring: bounded minute-by-minute search. See the bash comment above
    # this python block for why 8 days is always enough.
    t = now.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
    for _ in range(8 * 24 * 60):
        if t.month in months and t.minute in minutes and t.hour in hours:
            dom_ok = t.day in doms
            dow_ok = (t.weekday() + 1) % 7 in dows  # Mon=0..Sun=6 -> cron Sun=0..Sat=6
            if dom_wild and dow_wild:
                day_ok = True
            elif dom_wild:
                day_ok = dow_ok
            elif dow_wild:
                day_ok = dom_ok
            else:
                # vixie-cron semantics: when BOTH fields are restricted, a
                # match on either is sufficient.
                day_ok = dom_ok or dow_ok
            if day_ok:
                return t
        t += datetime.timedelta(minutes=1)
    return None


now_override = os.environ.get("WAKEUP_STATUS_NOW_EPOCH")
if now_override:
    try:
        now = datetime.datetime.fromtimestamp(int(now_override))
    except (ValueError, OSError, OverflowError):
        now = datetime.datetime.now()
else:
    now = datetime.datetime.now()

try:
    entries = json.load(sys.stdin)
except Exception:
    entries = []
if not isinstance(entries, list):
    entries = []

best_fire = None
best_prompt = ""
for entry in entries:
    if not isinstance(entry, dict):
        continue
    schedule = entry.get("schedule")
    if not isinstance(schedule, str):
        continue
    try:
        fire = next_fire(schedule, bool(entry.get("recurring")), now)
    except Exception:
        continue
    if fire is None:
        continue
    if best_fire is None or fire < best_fire:
        best_fire = fire
        prompt = entry.get("prompt")
        best_prompt = prompt if isinstance(prompt, str) else ""

if best_fire is not None:
    print(int(best_fire.timestamp()))
    print(best_prompt)
' 2>/dev/null || true)

# ----------------------------------------------------------------------------
# Step 10: No computable earliest fire (every entry unparseable, or every
#   recurring entry's next match fell outside the 8-day search horizon) --
#   same clearing path as "nothing scheduled". Showing a stale or wrong time
#   is worse than showing nothing.
# ----------------------------------------------------------------------------
if [ -z "$result" ]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

epoch=""
label=""
{
    IFS= read -r epoch
    IFS= read -r label
} <<< "$result"

if [[ ! "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

label=$(_sanitize_and_cap "$label")

_write_sidecar "$epoch" "$label" || true

exit 0
