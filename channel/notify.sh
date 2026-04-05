#!/usr/bin/env bash
#
# notify.sh — Send a message to the Claude webhook session that is an ancestor of this process.
#
# Usage: notify.sh <message>
#
set -euo pipefail

NODE=$(which node 2>/dev/null || echo /usr/local/bin/node)

find_claude_port() {
  local registry="$HOME/.claude_session_id_to_port"
  [ -f "$registry" ] || { echo "[notify.sh DEBUG] No registry file" >&2; return 1; }

  # Get all registered Claude PIDs from registry
  local claude_pids
  claude_pids=$("$NODE" -e "
    const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
    console.log(Object.keys(r).join('\n'));
  " -- "$registry" 2>/dev/null)

  [ -z "$claude_pids" ] && { echo "[notify.sh DEBUG] Registry empty" >&2; return 1; }

  echo "[notify.sh DEBUG] Registry: $(cat $registry)" >&2
  echo "[notify.sh DEBUG] Registered Claude PIDs: $claude_pids" >&2

  # Walk up from current shell
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    echo "[notify.sh DEBUG] Checking if any Claude PID has parent=$pid" >&2

    for claude_pid in $claude_pids; do
      # Get parent of this Claude PID
      local claude_parent
      claude_parent=$(ps -p "$claude_pid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$claude_parent" ] && continue  # Claude PID no longer exists

      echo "[notify.sh DEBUG]   Claude PID=$claude_pid has parent=$claude_parent" >&2

      if [ "$claude_parent" = "$pid" ]; then
        # Found! This Claude process is a sibling/cousin
        local port
        port=$("$NODE" -e "
          const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
          process.stdout.write(String(r[process.argv[2]] || ''));
        " -- "$registry" "$claude_pid" 2>/dev/null)

        if [ -n "$port" ] && [ "$port" != "undefined" ]; then
          echo "[notify.sh DEBUG] Found port=$port for Claude PID=$claude_pid (sibling of ancestor=$pid)" >&2
          echo "$port"
          return 0
        fi
      fi
    done

    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done

  echo "[notify.sh DEBUG] No sibling Claude session found" >&2
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
