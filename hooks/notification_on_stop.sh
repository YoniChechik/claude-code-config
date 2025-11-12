#!/bin/bash
# Hook that runs when Claude finishes responding
# Sends a notification to VS Code with terminal title

# Get the current terminal title (terminal name in VS Code)
TERMINAL_TITLE="Task complete"

# Send notification via HTTP to VS Code extension
curl -X POST http://localhost:3456 \
  -H "Content-Type: application/json" \
  -d "{\"command\":\"pingTerminalTitle\",\"args\":[]}" \
  &> /dev/null &
