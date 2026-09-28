#!/usr/bin/env bash
# ============================================================================
# user_prompt_submit__reset_color.sh
# ----------------------------------------------------------------------------
# Purpose:
#   UserPromptSubmit hook — fires the instant a new turn begins (a manually
#   typed prompt, or a /loop/cron wakeup resumption). Clears any tab color
#   left over from the PREVIOUS Stop/Notification right away, rather than
#   waiting for the first tool call: a turn that starts with plain text or
#   thinking, with no tool call for a while, would otherwise leave the old
#   idle-green (or armed-blue) tab sitting there through the whole "working"
#   phase. post_tool_use__reset_color.sh still covers mid-turn resets (e.g.
#   clearing a pink Notification the moment its blocking tool actually runs).
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr.
# ============================================================================

set -uo pipefail

cat >/dev/null

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

reset_tab_color

exit 0
