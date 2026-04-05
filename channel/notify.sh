#!/usr/bin/env bash
#
# notify.sh — Send a message to the Claude webhook session that is an ancestor of this process.
#
# Usage: notify.sh <message>
#
set -euo pipefail

find_claude_port() {
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    # Check if this process has CLAUDECODE=1 in its environment
    if ps eww -p "$pid" 2>/dev/null | grep -q 'CLAUDECODE=1'; then
      local port_file="$HOME/.claude/sessions/${pid}.port"
      if [ -f "$port_file" ]; then
        cat "$port_file"
        return 0
      fi
    fi
    # Walk up to parent
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

MESSAGE="$*"
PORT=$(find_claude_port)
if [ -z "$PORT" ]; then
  echo "notify.sh: no active Claude webhook session found" >&2
  exit 1
fi
RESPONSE=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" -d "$MESSAGE")
if [ "$RESPONSE" = "ok" ]; then
  echo "Notified Claude session on port $PORT"
else
  echo "notify.sh: unexpected response: $RESPONSE" >&2
  exit 1
fi
