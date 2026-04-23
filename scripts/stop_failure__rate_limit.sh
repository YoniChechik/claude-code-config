#!/usr/bin/env bash

# StopFailure hook — triggered when Claude stops due to a rate_limit error.
# 1. Sets the iTerm2 tab BADGE to "⏳ RATE LIMITED (OrgName)" so the user
#    notices at a glance which org/account is rate-limited.
#    (Badge used instead of title because Claude Code overrides the title.)
# 2. Logs the full hook JSON payload to ~/.claude/logs/rate_limit.log for inspection.

# ---------------------------------------------------------------------------
# Read the hook JSON payload from stdin (Claude Code passes it here)
# ---------------------------------------------------------------------------
INPUT=$(cat)

# ---------------------------------------------------------------------------
# Log the raw payload so we can inspect available fields later.
# Create the logs dir in case it was deleted.
# ---------------------------------------------------------------------------
LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $INPUT" >> "$LOG_DIR/rate_limit.log"

# ---------------------------------------------------------------------------
# Extract the current organization name from ~/.claude.json.
# The file contains oauthAccount.organizationName (set by Claude Code on login).
# Fall back to a blank string so the title still renders if the file is missing.
# ---------------------------------------------------------------------------
CLAUDE_JSON="$HOME/.claude.json"
if command -v python3 &>/dev/null && [ -f "$CLAUDE_JSON" ]; then
    ORG_NAME=$(python3 -c "
import json, sys
try:
    d = json.load(open('$CLAUDE_JSON'))
    print(d.get('oauthAccount', {}).get('organizationName', ''))
except Exception:
    print('')
" 2>/dev/null)
fi

# Build the title: append the org name in parentheses only when it is non-empty.
if [ -n "$ORG_NAME" ]; then
    TAB_TITLE="⏳ RATE LIMITED ($ORG_NAME)"
else
    TAB_TITLE="⏳ RATE LIMITED"
fi

# ---------------------------------------------------------------------------
# Set iTerm2 tab BADGE to a visible rate-limit indicator.
# We use the badge instead of the tab title because Claude Code overrides
# the tab title (\033]0;) after hooks run, so our title change disappears.
# The badge (iTerm2 proprietary) is untouched by Claude Code and persists.
# Escape sequence: \e]1337;SetBadgeFormat=<base64>\a
# Write to /dev/tty — Claude Code captures stdout from hooks, so escape
# sequences must go directly to the terminal via /dev/tty instead.
# ---------------------------------------------------------------------------
printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$TAB_TITLE" | base64)" > /dev/tty 2>/dev/null || true

# ---------------------------------------------------------------------------
# Also set the tab color to orange (high red + medium green, no blue)
# to visually distinguish it from the idle-green used by the Stop hook.
# Escape sequence format: \033]6;1;bg;<channel>;brightness;<0-255>\a
# ---------------------------------------------------------------------------
printf '\033]6;1;bg;red;brightness;255\a\033]6;1;bg;green;brightness;140\a\033]6;1;bg;blue;brightness;0\a' > /dev/tty 2>/dev/null || true
