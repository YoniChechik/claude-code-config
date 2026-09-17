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
# Logs the full hook JSON payload to ~/.claude/logs/rate_limit.log for
# inspection. status_line.sh renders the actual rate-limit percentage
# independently, straight from the statusLine payload's own
# .rate_limits.five_hour fields — this hook does not feed that display.

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
