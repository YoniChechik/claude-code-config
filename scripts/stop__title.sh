#!/usr/bin/env bash

# Stop hook — triggered when Claude finishes a session/turn.
# Sets the iTerm2 tab BADGE to "✅ Done (OrgName)" so the user
# can see at a glance that Claude is idle and which org is active.
# (Badge used instead of title because Claude Code overrides the title.)

# ---------------------------------------------------------------------------
# Read the hook JSON payload from stdin (Claude Code passes it here)
# ---------------------------------------------------------------------------
INPUT=$(cat)

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
    TAB_TITLE="✅ Done ($ORG_NAME)"
else
    TAB_TITLE="✅ Done"
fi

# ---------------------------------------------------------------------------
# Set iTerm2 tab BADGE to a visible done indicator.
# We use the badge instead of the tab title because Claude Code overrides
# the tab title (\033]0;) after hooks run, so our title change disappears.
# The badge (iTerm2 proprietary) is untouched by Claude Code and persists.
# Escape sequence: \e]1337;SetBadgeFormat=<base64>\a
# Write to /dev/tty — same pattern as color sequences in other hooks.
# ---------------------------------------------------------------------------
printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$TAB_TITLE" | base64)" > /dev/tty 2>/dev/null || true
