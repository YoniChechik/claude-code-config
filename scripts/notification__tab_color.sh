#!/usr/bin/env bash
# ============================================================================
# notification__tab_color.sh
# ----------------------------------------------------------------------------
# Purpose:
#   Notification hook — Claude Code fires this when it needs the user's
#   attention right now (a permission prompt, an idle-timeout nudge, etc.).
#   Paints the iTerm2 tab PINK unconditionally: whatever background work may
#   still be armed, something is blocking on the user this instant, which
#   outranks it.
#
# Invariant: EVERY path ends in `exit 0` with nothing on stderr.
# ============================================================================

set -uo pipefail

cat >/dev/null

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

set_tab_pink

exit 0
