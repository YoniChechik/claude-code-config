#!/usr/bin/env bash

# StopFailure hook — triggered when Claude stops due to a rate_limit error.
# 1. Sets the iTerm2 tab title to "⏳ RATE LIMITED" so the user notices at a glance.
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
# Set iTerm2 tab title to a visible rate-limit indicator.
# \033]0;<title>\007 sets both the window title and the tab title in iTerm2.
# We write directly to /dev/tty so it works even when stdout is captured.
# ---------------------------------------------------------------------------
printf '\033]0;⏳ RATE LIMITED\007' > /dev/tty 2>/dev/null || true

# ---------------------------------------------------------------------------
# Also set the tab color to orange (high red + medium green, no blue)
# to visually distinguish it from the idle-green used by the Stop hook.
# Escape sequence format: \033]6;1;bg;<channel>;brightness;<0-255>\a
# ---------------------------------------------------------------------------
printf '\033]6;1;bg;red;brightness;255\a\033]6;1;bg;green;brightness;140\a\033]6;1;bg;blue;brightness;0\a' > /dev/tty 2>/dev/null || true
