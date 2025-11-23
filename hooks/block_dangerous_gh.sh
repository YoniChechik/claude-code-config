#!/bin/bash
# Only allow gh pr commands (except force push). Block everything else.
# Exit code 2 = blocking error (per Claude Code hooks documentation)

# Parse the command from CLAUDE_TOOL_INPUT
if [ -z "$CLAUDE_TOOL_INPUT" ]; then
    # If CLAUDE_TOOL_INPUT is not provided, allow the command
    exit 0
fi

COMMAND=$(python3 -c "import sys, json; data = json.loads(sys.stdin.read()); print(data.get('parameters', {}).get('command', ''))" <<< "$CLAUDE_TOOL_INPUT" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$COMMAND" ] || [ "$COMMAND" = "null" ]; then
    # If we can't parse the command, allow it
    exit 0
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
    if echo "$COMMAND" | grep -qE '(--force|-f)'; then
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
