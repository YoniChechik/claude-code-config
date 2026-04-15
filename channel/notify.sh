#!/usr/bin/env bash
#
# notify.sh — Send a message to the Claude webhook session.
#
# Port resolution order:
#   1. $CLAUDE_WEBHOOK_PORT env var (set by CI watcher launcher, etc.)
#   2. Ancestry walk (finds the Claude session that is an ancestor of this process)
#
# Usage: notify.sh <message>
#
set -euo pipefail

# Source the shared port-resolution helper
source "$HOME/.claude/scripts/_webhook_port.sh"

MESSAGE="$*"
PORT=$(find_claude_port) || { echo "notify.sh: no active Claude webhook session found" >&2; exit 1; }
RESPONSE=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "$MESSAGE")
if [ "$RESPONSE" = "ok" ]; then
  echo "Notified Claude session on port $PORT"
else
  echo "notify.sh: unexpected response from port $PORT: $RESPONSE" >&2
  exit 1
fi
