#!/usr/bin/env bash
# ============================================================================
# stop__tab_color.sh
# ----------------------------------------------------------------------------
# Purpose:
#   Stop hook that paints the iTerm2 tab BLUE when this session stopped with a
#   /loop, CronCreate, or ScheduleWakeup timer still armed (background work is
#   still going — the session will resume on its own), or GREEN when nothing
#   is pending (fully idle, needs the user).
#
#   Reuses the same `session_crons` field stop__wakeup_status.sh already reads
#   off the Stop hook input — an armed entry there is precisely "background
#   work still in flight" for a /loop, so no separate detector is needed.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr.
# ============================================================================

set -uo pipefail

input=$(cat)

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# Same "nothing scheduled" collapse as stop__wakeup_status.sh: key absent,
# null, or `[]` all read as empty; unparseable input fails the same way via
# `2>/dev/null`.
entries=$(jq -c '(.session_crons // []) | select(length>0)' <<< "$input" 2>/dev/null)

if [ -n "$entries" ]; then
    set_tab_blue
else
    set_tab_green
fi

exit 0
