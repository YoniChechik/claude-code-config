#!/usr/bin/env bash

# StopFailure hook — triggered when Claude stops due to a rate_limit error.
# 1. Sets the iTerm2 tab BADGE so the user notices at a glance which
#    org/account is rate-limited AND which variant of the limit message
#    fired. Two variants are recognised (see VARIANT DETECTION below):
#      - Team/Max account:   "You've hit your limit · resets …"
#      - Personal Pro:       "You're out of extra usage · resets …"
#                            (also covers "/extra-usage" upsell text)
#    Badge used instead of title because Claude Code overrides the title.
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
    ORG_NAME=$(CLAUDE_JSON="$CLAUDE_JSON" python3 - <<'PY' 2>/dev/null
import json, os
try:
    with open(os.environ["CLAUDE_JSON"]) as f:
        d = json.load(f)
    print(d.get("oauthAccount", {}).get("organizationName", ""))
except Exception:
    print("")
PY
)
fi
ORG_NAME="${ORG_NAME:-}"

# ---------------------------------------------------------------------------
# VARIANT DETECTION
# ---------------------------------------------------------------------------
# Both the team/Max-account and personal-Pro-account 5h-window-exhausted
# events arrive with the same top-level `error: "rate_limit"` field — the
# Claude Code hook matcher fires on both. We additionally inspect the
# `last_assistant_message` field (added to Stop/StopFailure hook payloads;
# see changelog entry "Added last_assistant_message field to Stop and
# SubagentStop hook inputs") to pick a more descriptive badge.
#
# Observed message variants (sample payloads in ~/.claude/logs/rate_limit.log):
#   Team/Max:   "You've hit your limit · resets 2:20pm (Asia/Jerusalem)"
#   Pro:        "You're out of extra usage · resets 2pm (Asia/Jerusalem)"
#               (Pro accounts can also see "/extra-usage" upsell text.)
#
# We use a single grep -E alternation covering both wordings so adding a
# new variant in the future is a one-line change.
# ---------------------------------------------------------------------------
LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
LAST_MSG="${LAST_MSG:-}"

# Default label — used when neither known variant matches (forward-compat
# for any future rate-limit message Claude Code may introduce).
VARIANT_LABEL="RATE LIMITED"

# Match the team/Max wording first ("hit your limit").
if printf '%s' "$LAST_MSG" | grep -qE "hit your limit"; then
    VARIANT_LABEL="RATE LIMITED"
# Match the personal-Pro wording ("out of extra usage" or "/extra-usage").
elif printf '%s' "$LAST_MSG" | grep -qE "out of extra usage|/extra-usage"; then
    VARIANT_LABEL="OUT OF EXTRA USAGE"
fi

# Build the badge: append the org name in parentheses only when non-empty.
if [ -n "$ORG_NAME" ]; then
    TAB_TITLE="⏳ ${VARIANT_LABEL} (${ORG_NAME})"
else
    TAB_TITLE="⏳ ${VARIANT_LABEL}"
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
