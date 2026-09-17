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
# ============================================================================

# Strict mode WITHOUT -e on purpose: a missing state file or a failed write
# must degrade to "exit 0 silently", never abort the hook with an error.
set -uo pipefail

state_dir="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}"

# ----------------------------------------------------------------------------
# Step 1: Drain stdin once so Claude Code never blocks waiting on us.
# ----------------------------------------------------------------------------
input=$(cat)

# ----------------------------------------------------------------------------
# Step 2: Pull the session id off the payload. Without it there is no
#   per-session state to key, so exit silently.
# ----------------------------------------------------------------------------
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$session_id" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 3: The per-session "last fired" timestamp file, same sidecar convention
#   as scripts/_notify.sh and skills/session-name/SKILL.md.
# ----------------------------------------------------------------------------
state_file="${state_dir}/session_name_reminder_${session_id}"

# ----------------------------------------------------------------------------
# Step 4: One single `date` fork for the whole script.
# ----------------------------------------------------------------------------
now=$(date +%s)

# ----------------------------------------------------------------------------
# Step 5: Read the last-fired epoch. `-f` (regular files only) guards against a
#   FIFO/socket at that path blocking us forever. A missing or non-numeric file
#   is a cold start, not a "due" reminder.
# ----------------------------------------------------------------------------
cold_start=0
last_fired=0
if [ -f "$state_file" ]; then
    last_fired="$(cat "$state_file" 2>/dev/null || echo 0)"
    [[ "$last_fired" =~ ^[0-9]+$ ]] || { last_fired=0; cold_start=1; }
else
    cold_start=1
fi

# ----------------------------------------------------------------------------
# Step 6: Cold start only starts the clock — it emits nothing.
# ----------------------------------------------------------------------------
if (( cold_start )); then
    tmp="$(mktemp "${state_dir}/session_name_reminder_XXXXXX")" || exit 0
    printf '%s' "$now" > "$tmp" && mv -f "$tmp" "$state_file"
    rm -f "$tmp"
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 7: The common, silent case. A negative delta (clock skew) is clamped to
#   0 so it can never underflow into "due".
# ----------------------------------------------------------------------------
delta=$(( now - last_fired ))
if (( delta < 0 )); then
    delta=0
fi
if (( delta <= 1800 )); then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 8: Firing. Reset the clock FIRST, atomically (mktemp + mv -f, never a
#   direct `>` truncate onto the state file), so a concurrent reader never sees
#   a half-written value.
# ----------------------------------------------------------------------------
tmp="$(mktemp "${state_dir}/session_name_reminder_XXXXXX")" || exit 0
if ! printf '%s' "$now" > "$tmp" || ! mv -f "$tmp" "$state_file"; then
    rm -f "$tmp"
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 9: Emit the reminder as Stop "additionalContext". Built with
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
