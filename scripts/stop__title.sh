#!/usr/bin/env bash

# Stop hook — triggered when Claude finishes a session/turn.
# Sets the iTerm2 tab title to "✅ Done (OrgName)" so the user
# can see at a glance that Claude is idle and which org is active.

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
# Set iTerm2 tab title to a visible done indicator.
# \033]0;<title>\007 sets both the window title and the tab title in iTerm2.
# Write to /dev/tty — the same method used by stop__sound.sh and
# user_prompt_submit.sh, which both work correctly in hook context.
# ---------------------------------------------------------------------------
printf '\033]0;%s\007' "$TAB_TITLE" > /dev/tty 2>/dev/null || true
