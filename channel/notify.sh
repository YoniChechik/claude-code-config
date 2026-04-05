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
  [ -f "$registry" ] || return 1

  local claude_pids
  claude_pids=$("$NODE" -e "
    const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
    console.log(Object.keys(r).join('\n'));
  " -- "$registry" 2>/dev/null)
  [ -z "$claude_pids" ] && return 1

  # Build notify.sh's full ancestry set
  local my_ancestors=""
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    my_ancestors="$my_ancestors $pid"
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done
  # For each registered Claude PID, walk its ancestry until hitting one of our ancestors
  for claude_pid in $claude_pids; do
    # Verify Claude PID is still alive
    ps -p "$claude_pid" > /dev/null 2>&1 || continue

    local cpid="$claude_pid"
    while [ "$cpid" -gt 1 ]; do
      if echo "$my_ancestors" | grep -qw "$cpid"; then
        # Get the port for this Claude PID
        local port
        port=$("$NODE" -e "
          const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
          process.stdout.write(String(r[process.argv[2]] || ''));
        " -- "$registry" "$claude_pid" 2>/dev/null)
        if [ -n "$port" ] && [ "$port" != "undefined" ]; then
          echo "$port"
          return 0
        fi
      fi
      cpid=$(ps -p "$cpid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$cpid" ] && break
    done
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
