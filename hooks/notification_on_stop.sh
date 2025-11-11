#!/bin/bash
# Hook that runs when Claude finishes responding
# Sends a notification to VS Code with terminal title

# Only send notification if ch command is available
if command -v ch &> /dev/null; then
    # Send ping with terminal title to notify task is complete
    ch ping-terminal-title &> /dev/null &
fi
