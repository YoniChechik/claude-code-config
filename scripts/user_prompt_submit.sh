#!/bin/bash

# UserPromptSubmit hook: reset the iTerm2 tab decorations now that Claude is processing.
# Emits nothing on stdout — it must not inject text into the prompt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the shared notify helper so we can reuse find_user_tty() — the
# helper walks the PPID chain to locate the user's real terminal device,
# which is more reliable than /dev/tty when the hook is invoked from a
# subagent context with a detached stdout.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_notify.sh"

TARGET_TTY=$(find_user_tty 2>/dev/null || true)
if [ -z "$TARGET_TTY" ] || [ ! -w "$TARGET_TTY" ]; then
    TARGET_TTY=/dev/tty
fi

# Reset iTerm2 tab to default — Claude is now processing. Goes through
# reset_tab_color rather than a raw escape sequence so it also drops the
# last-painted-state record the PostToolUse reset hook reads; a hand-rolled
# printf here would leave a stale "green" behind.
reset_tab_color

# Clear the iTerm2 tab badge so it doesn't persist while Claude is busy.
# The badge was set to "✅ Done (OrgName)" or "⏳ RATE LIMITED (OrgName)"
# by stop__title.sh / stop_failure__rate_limit.sh when Claude last stopped.
printf '\e]1337;SetBadgeFormat=\a' > "$TARGET_TTY" 2>/dev/null || true

exit 0
