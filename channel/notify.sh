#!/usr/bin/env bash
#
# notify.sh — Send a message to the Claude webhook session that is an ancestor of this process.
#
# Usage: notify.sh <message>
#
set -euo pipefail

NODE=$(which node 2>/dev/null || echo /usr/local/bin/node)

find_claude_port() {
  local pid=$$
  local registry="$HOME/.claude_session_id_to_port"

  [ -f "$registry" ] || return 1

  while [ "$pid" -gt 1 ]; do
    if ps eww -p "$pid" 2>/dev/null | grep -q 'CLAUDECODE=1'; then
      local port
      port=$("$NODE" -e "
        const [,, reg, pid] = process.argv;
        try { const r=JSON.parse(require('fs').readFileSync(reg,'utf8')); process.stdout.write(String(r[pid]||'')); } catch{}
      " -- "$registry" "$pid")
      if [ -n "$port" ] && [ "$port" != "undefined" ]; then
        echo "$port"
        return 0
      fi
    fi
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
RESPONSE=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "$MESSAGE")
if [ "$RESPONSE" = "ok" ]; then
  echo "Notified Claude session on port $PORT"
else
  echo "notify.sh: unexpected response: $RESPONSE" >&2
  exit 1
fi
