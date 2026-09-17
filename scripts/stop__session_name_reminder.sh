#!/usr/bin/env bash
# ============================================================================
# stop__session_name_reminder.sh
# ----------------------------------------------------------------------------
# Purpose:
#   Stop hook that periodically reminds CLAUDE (not the user) to check whether
#   the session's task or scope changed since the session name was set, and to
#   re-run /session-name if it did.
#
# Why a cadence, not every Stop:
#   The Stop hook fires after EVERY Claude response. A per-session timestamp
#   file records when this reminder last fired; the reminder is emitted again
#   only after more than 30 minutes have passed. Every other Stop exits
#   silently with no output at all.
#
# Mechanism:
#   Claude Code sends a JSON payload on stdin containing .session_id. To inject
#   context, this hook MUST run synchronously (no "async": true in
#   settings.json) and print a JSON object on stdout following the Stop
#   "hookSpecificOutput" schema. Only additionalContext is emitted — no
#   decision/reason, no systemMessage — so the nudge is model-facing.
#
# Cold start (no state file yet, or a corrupt one) only initializes the clock;
# it never fires, because the SessionStart hook already delivers the same
# guidance once at session start.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr. A hook that
# fails loudly is worse than a nudge that is skipped.
#
# Concurrency — deliberately NOT locked:
#   The read-check-write sequence is not atomic as a whole (only each state
#   write is). Two truly concurrent Stop events for the SAME session id could
#   therefore both fire. That is accepted, not fixed:
#     * Claude Code runs one turn at a time per session, so two concurrent Stop
#       events for one session id is not a real execution mode.
#     * The worst case is one duplicate model-facing nudge, which self-corrects
#       at the next interval.
#     * macOS ships no `flock`, so any portable lock (mkdir/ln/noclobber) is a
#       stale-lock wedge: a process killed while holding it disables the
#       reminder for that session PERMANENTLY. That failure is strictly worse
#       than a duplicate nudge, so the lock would cost more than it buys.
# ============================================================================

# Strict mode WITHOUT -e on purpose: a missing state file or a failed write
# must degrade to "exit 0 silently", never abort the hook with an error.
set -uo pipefail

# ----------------------------------------------------------------------------
# Step 1: Drain stdin once so Claude Code never blocks waiting on us.
# ----------------------------------------------------------------------------
input=$(cat)

# ----------------------------------------------------------------------------
# Step 2: Pull the session id off the payload. Without it there is no
#   per-session state to key, so exit silently. A herestring instead of
#   `printf ... | jq` keeps this hot path down to a single fork.
# ----------------------------------------------------------------------------
session_id=$(jq -r '.session_id // empty' <<< "$input" 2>/dev/null)
if [ -z "$session_id" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 3: The session id goes straight into a filesystem path, so it must be a
#   single safe path component. Claude Code sends a UUID. Anything holding `/`,
#   `..`, a quote or a shell metacharacter is rejected here rather than pasted
#   into a path, which is what keeps the state file inside $state_dir and keeps
#   a failing `mv` from printing to stderr.
# ----------------------------------------------------------------------------
if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 4: Config. The per-session "last fired" timestamp file uses the same
#   sidecar convention as scripts/_notify.sh and skills/session-name/SKILL.md.
# ----------------------------------------------------------------------------
readonly REMINDER_INTERVAL_SECONDS=1800
state_dir="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}"
state_file="${state_dir}/session_name_reminder_${session_id}"

# ----------------------------------------------------------------------------
# Step 5: The single atomic state writer, shared by every branch that resets
#   the clock. Writes to a sibling temp file and renames it over the state
#   file, so a concurrent reader never sees a half-written value. Never a
#   direct `>` truncate onto the state file. Returns non-zero on any failure;
#   the temp file is removed on that path so nothing leaks.
# ----------------------------------------------------------------------------
_write_state() {
    local tmp
    tmp="$(mktemp "${state_dir}/session_name_reminder_XXXXXX" 2>/dev/null)" || return 1
    if ! printf '%s' "$1" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$state_file" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 6: One single `date` fork for the whole script.
# ----------------------------------------------------------------------------
now=$(date +%s)

# ----------------------------------------------------------------------------
# Step 7: Refuse to touch the path if something that is not a regular file is
#   already sitting there. A directory would silently swallow every `mv` as a
#   file created INSIDE it — one leaked temp file per Stop, forever, and the
#   state file never established. A FIFO or socket would block the read.
# ----------------------------------------------------------------------------
if [ -e "$state_file" ] && [ ! -f "$state_file" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 8: Read the last-fired epoch with the `read` builtin (no fork) and cap
#   it at 32 bytes, mirroring the `head -c 512` cap in _notify.sh: the path is
#   predictable and lives in a shared /tmp, so a planted multi-megabyte file
#   must never be slurped into memory.
#
#   The regex rejects a leading zero on purpose. `$(( ))` reads a leading-zero
#   operand as OCTAL, so a stored "09" would pass a naive ^[0-9]+$ and then
#   abort the script with "value too great for base" — a visible error and a
#   non-zero exit, breaking this hook's core invariant. `date +%s` never emits
#   a leading zero, so such a value is by definition corrupt. "0" is likewise
#   treated as corrupt: epoch 0 means the clock is broken, not that the
#   reminder last fired in 1970.
# ----------------------------------------------------------------------------
cold_start=0
last_fired=0
if [ -f "$state_file" ]; then
    read -r -n 32 last_fired < "$state_file" 2>/dev/null
    [[ "$last_fired" =~ ^[1-9][0-9]*$ ]] || cold_start=1
else
    cold_start=1
fi

# ----------------------------------------------------------------------------
# Step 9: Cold start only starts the clock — it emits nothing.
# ----------------------------------------------------------------------------
if (( cold_start )); then
    _write_state "$now"
    exit 0
fi

delta=$(( now - last_fired ))

# ----------------------------------------------------------------------------
# Step 10: A negative delta means the stored timestamp is in the future —
#   clock skew, or a corrupt-but-numeric value such as a far-future epoch.
#   Rewrite the clock instead of only clamping the delta: clamping alone would
#   leave the bad value in place and wedge the reminder off until the real
#   clock caught up, which for a large stored value could be years.
# ----------------------------------------------------------------------------
if (( delta < 0 )); then
    _write_state "$now"
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 11: The common, silent case.
# ----------------------------------------------------------------------------
if (( delta <= REMINDER_INTERVAL_SECONDS )); then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 12: Firing. Reset the clock FIRST; if the reset cannot be persisted,
#   stay silent rather than nudge on every single Stop from here on.
# ----------------------------------------------------------------------------
_write_state "$now" || exit 0

# ----------------------------------------------------------------------------
# Step 13: Emit the reminder as Stop "additionalContext". Built with
#   `jq -n --arg` so the backticks/apostrophes in the text are always escaped
#   into valid JSON.
# ----------------------------------------------------------------------------
reminder="Periodic reminder: this session has been active for a while. Check whether this session's task or scope has changed since the session name was last set. Re-run \`/session-name\` any time the task changes, since the label must always match what the session is currently doing right now, not what it started as. If the scope has not changed, no action is needed."

jq -n --arg text "$reminder" '{
    hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: $text
    }
}'

exit 0
