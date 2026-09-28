#!/usr/bin/env bash
# ============================================================================
# stop__tab_color.sh
# ----------------------------------------------------------------------------
# Purpose:
#   Stop hook that paints the iTerm2 tab BLUE when this session stopped with
#   ANY background work still in flight - a /loop, CronCreate, or
#   ScheduleWakeup timer armed (`session_crons`), OR a backgrounded shell /
#   subagent / MCP task / workflow still running or pending
#   (`background_tasks`) - since either one means the session will resume on
#   its own; GREEN when both are empty (fully idle, needs the user).
#
#   `session_crons` is "Session-scoped cron tasks (CronCreate, ScheduleWakeup,
#   /loop) that will wake this session later." `background_tasks` is
#   "In-flight background work (running/pending + backgrounded) registered in
#   this session" - e.g. a `run_in_background: true` Bash call or a
#   background Agent/subagent - "Lets hooks distinguish 'session is done'
#   from 'session is paused waiting for background work to wake it'." (both
#   descriptions verbatim from the hook input schema shipped in the Claude
#   Code CLI itself). Checking only `session_crons` missed the
#   `background_tasks` case entirely, painting a session with a live
#   backgrounded Bash job GREEN ("fully idle") right up until the moment it
#   silently resumed on its own - confirmed empirically 2026-09-28.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr.
# ============================================================================

set -uo pipefail

input=$(cat)

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# Same "nothing scheduled/running" collapse as stop__wakeup_status.sh: key
# absent, null, or `[]` all read as empty; unparseable input fails the same
# way via `2>/dev/null`.
crons=$(jq -c '(.session_crons // []) | select(length>0)' <<< "$input" 2>/dev/null)
tasks=$(jq -c '(.background_tasks // []) | select(length>0)' <<< "$input" 2>/dev/null)

if [ -n "$crons" ] || [ -n "$tasks" ]; then
    set_tab_blue
else
    set_tab_green
fi

exit 0
