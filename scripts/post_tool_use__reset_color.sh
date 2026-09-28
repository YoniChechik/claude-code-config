#!/usr/bin/env bash
# ============================================================================
# post_tool_use__reset_color.sh
# ----------------------------------------------------------------------------
# Purpose:
#   PostToolUse hook (every tool, no matcher) — clears a painted tab color the
#   moment the session is running a tool again, foreground activity having
#   resumed (either a fresh turn, or a /loop's scheduled wakeup firing and
#   picking back up). reset_tab_color() writes the reset escape
#   unconditionally (cheap either way), so a default tab is unaffected.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr.
# ============================================================================

set -uo pipefail

cat >/dev/null

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

reset_tab_color

exit 0
