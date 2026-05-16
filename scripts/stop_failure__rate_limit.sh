#!/usr/bin/env bash

# StopFailure hook — triggered when Claude stops due to a rate_limit error.
#
# IMPORTANT (verified 2026-05-13): the matcher value `rate_limit` in
# settings.json fires for BOTH variants of the rate-limit StopFailure event
# (the docs at https://code.claude.com/docs/en/hooks list valid StopFailure
# matchers as: rate_limit, authentication_failed, oauth_org_not_allowed,
# billing_error, invalid_request, server_error, max_output_tokens, unknown —
# there is NO separate matcher for "extra usage exhausted"). Empirical proof:
# ~/.claude/logs/rate_limit.log contains many entries with
#   "error":"rate_limit","last_assistant_message":"You're out of extra usage …"
# alongside the team-account "You've hit your limit …" variant.
#
# 1. Sets the iTerm2 tab BADGE so the user notices at a glance which
#    org/account is rate-limited AND which variant of the limit message
#    fired. Two wordings are recognised (see VARIANT DETECTION below):
#      - Team/Max account:   "You've hit your limit · resets …"
#      - Personal Pro:       "You're out of extra usage · resets …"
#                            (also covers "/extra-usage" upsell text)
#    Badge used instead of title because Claude Code overrides the title.
# 2. Plays an audible sound so the user notices even when the iTerm window
#    is in the background. Without this the badge change is easy to miss
#    (see PR fix: "the hook fires but the user said 'it didn't trigger' —
#    that meant no audible signal").
# 3. Logs the full hook JSON payload to ~/.claude/logs/rate_limit.log for inspection.

# Source the shared notify helper so we can reuse find_user_tty() — the
# helper walks the PPID chain to locate the user's real terminal device,
# which is more reliable than /dev/tty when the hook is invoked from a
# subagent context with a detached stdout.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

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
# Resolve the user's real terminal device by walking the PPID chain.
# When invoked from a subagent context Claude Code may capture /dev/tty,
# so escape sequences need to be written to the user-facing tty directly.
# Fall back to /dev/tty if the helper can't find one (interactive case).
# ---------------------------------------------------------------------------
TARGET_TTY=$(find_user_tty 2>/dev/null || true)
if [ -z "$TARGET_TTY" ] || [ ! -w "$TARGET_TTY" ]; then
    TARGET_TTY=/dev/tty
fi

# ---------------------------------------------------------------------------
# AUDIBLE NOTIFICATION (shared helper)
# ---------------------------------------------------------------------------
# Previously this hook played a distinct sound (Funk.aiff) directly via
# afplay. We've since standardized on the shared notify_user_attention()
# helper from _notify.sh — the same one used by the permission_guard ask
# path and notification__sound.sh — so every "user, please come back"
# signal sounds the same. The helper plays Glass.aiff, sets the iTerm2
# tab color (green) and writes a "waiting…" title.
#
# IMPORTANT ORDERING: we call the helper FIRST and then set the
# rate-limit-specific orange tab color + badge below, so those override
# the helper's green color. The badge is untouched by the helper. The
# title written by the helper is overridden by Claude Code anyway (see
# badge comment below), so it does not conflict.
# _notify.sh is already sourced at the top of this script.
# ---------------------------------------------------------------------------
notify_user_attention

# ---------------------------------------------------------------------------
# Set iTerm2 tab BADGE to a visible rate-limit indicator.
# We use the badge instead of the tab title because Claude Code overrides
# the tab title (\033]0;) after hooks run, so our title change disappears.
# The badge (iTerm2 proprietary) is untouched by Claude Code and persists.
# Escape sequence: \e]1337;SetBadgeFormat=<base64>\a
# ---------------------------------------------------------------------------
printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$TAB_TITLE" | base64)" > "$TARGET_TTY" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Also set the tab color to orange (high red + medium green, no blue)
# to visually distinguish it from the idle-green used by the Stop hook.
# This intentionally overrides the green color that notify_user_attention
# just set, since rate-limit is a different state than "waiting for user".
# Escape sequence format: \033]6;1;bg;<channel>;brightness;<0-255>\a
# ---------------------------------------------------------------------------
printf '\033]6;1;bg;red;brightness;255\a\033]6;1;bg;green;brightness;140\a\033]6;1;bg;blue;brightness;0\a' > "$TARGET_TTY" 2>/dev/null || true
