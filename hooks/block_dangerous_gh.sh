#!/bin/bash
# Only allow gh pr commands (except force push). Block everything else.
# Exit code 2 = blocking error (per Claude Code hooks documentation)

# Parse the command from ARGUMENTS
if [ -z "$ARGUMENTS" ]; then
    echo "ERROR: No ARGUMENTS provided to hook" >&2
    echo "This hook expects ARGUMENTS to contain the bash command being executed." >&2
    echo "" >&2
    exit 2
fi

COMMAND=$(echo "$ARGUMENTS" | jq -r '.command' 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$COMMAND" ] || [ "$COMMAND" = "null" ]; then
    echo "ERROR: Failed to parse command from ARGUMENTS" >&2
    echo "ARGUMENTS content: $ARGUMENTS" >&2
    echo "" >&2
    exit 2
fi

# Check if it's a gh command
if ! echo "$COMMAND" | grep -qE '^gh '; then
    # Not a gh command - allow it
    echo "INFO: Command is not a gh command, allowing: $COMMAND" >&2
    exit 0
fi

# ALLOWED: gh pr commands (except force push)
if echo "$COMMAND" | grep -qE '^gh pr '; then
    # Block force push within PR commands
    if echo "$COMMAND" | grep -qE '--force|-f'; then
        echo "ERROR: Force push not allowed in gh pr commands!" >&2
        echo "Command attempted: $COMMAND" >&2
        echo "Force pushing can overwrite history and cause data loss." >&2
        echo "" >&2
        exit 2
    fi
    # Allow all other gh pr commands
    echo "INFO: Allowing gh pr command: $COMMAND" >&2
    exit 0
fi

# BLOCKED: All other gh commands
echo "ERROR: Only gh pr commands are allowed (non-PR gh commands blocked for safety)" >&2
echo "Command attempted: $COMMAND" >&2
echo "Allowed: gh pr <subcommand>" >&2
echo "Blocked: All other gh commands" >&2
echo "" >&2
exit 2
