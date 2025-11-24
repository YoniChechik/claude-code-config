#!/bin/bash
# Only allow gh pr commands (except merge). Block all other gh commands.
# Exit code 2 = blocking error (per Claude Code hooks documentation)

# Read JSON from stdin and parse the command
COMMAND=$(python3 -c "import sys, json; data = json.loads(sys.stdin.read()); print(data.get('tool_input', {}).get('command', ''))" 2>/dev/null)

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

# ALLOWED: gh pr commands (except merge)
if echo "$COMMAND" | grep -qE '^gh pr '; then
    # Block gh pr merge entirely
    if echo "$COMMAND" | grep -qE '^gh pr merge(\s|$)'; then
        echo "ERROR: gh pr merge not allowed (merge PRs manually via GitHub UI)" >&2
        echo "Command attempted: $COMMAND" >&2
        exit 2
    fi
    # Note: -f is --fill, -F is --body-file - both are safe
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
