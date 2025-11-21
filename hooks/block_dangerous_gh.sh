#!/bin/bash
# Only allow gh pr commands (except force push). Block everything else.
# Exit code 2 = blocking error (per Claude Code hooks documentation)

COMMAND=$(echo "$ARGUMENTS" | jq -r '.command')

# Check if it's a gh command
if ! echo "$COMMAND" | grep -qE '^gh '; then
    # Not a gh command - allow it
    exit 0
fi

# ALLOWED: gh pr commands (except force push)
if echo "$COMMAND" | grep -qE '^gh pr '; then
    # Block force push within PR commands
    if echo "$COMMAND" | grep -qE '--force|-f'; then
        echo 'BLOCKED: Force push not allowed in gh pr commands' >&2
        exit 2
    fi
    # Allow all other gh pr commands
    exit 0
fi

# BLOCKED: All other gh commands
echo 'BLOCKED: Only gh pr commands are allowed (non-PR gh commands blocked for safety)' >&2
exit 2
