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

  echo "[notify.sh DEBUG] Starting find_claude_port: PID=$$, PPID=$PPID" >&2

  if [ ! -f "$registry" ]; then
    echo "[notify.sh DEBUG] Registry file not found: $registry — returning failure" >&2
    return 1
  fi

  echo "[notify.sh DEBUG] Registry file contents:" >&2
  cat "$registry" >&2
  echo "" >&2

  while [ "$pid" -gt 1 ]; do
    echo "[notify.sh DEBUG] Checking PID=$pid for CLAUDECODE=1" >&2
    if ps eww -p "$pid" 2>/dev/null | grep -q 'CLAUDECODE=1'; then
      echo "[notify.sh DEBUG] CLAUDECODE=1 FOUND on PID=$pid" >&2
      local ppid_of_match
      ppid_of_match=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
      echo "[notify.sh DEBUG] PPID of match: $ppid_of_match" >&2
      local port
      # Try the matched PID first (it may be Claude itself), then its PPID
      # (in case this is a child shell that inherited CLAUDECODE=1).
      for candidate in "$pid" "$ppid_of_match"; do
        [ -n "$candidate" ] && [ "$candidate" -gt 0 ] 2>/dev/null || continue
        echo "[notify.sh DEBUG] Looking up candidate PID=$candidate in registry" >&2
        port=$("$NODE" -e "
          const [,, reg, pid] = process.argv;
          try { const r=JSON.parse(require('fs').readFileSync(reg,'utf8')); process.stdout.write(String(r[pid]||'')); } catch{}
        " -- "$registry" "$candidate")
        echo "[notify.sh DEBUG] Registry lookup for PID=$candidate returned: '${port:-<empty>}'" >&2
        if [ -n "$port" ] && [ "$port" != "undefined" ]; then
          echo "[notify.sh DEBUG] Final port found: $port" >&2
          echo "$port"
          return 0
        fi
      done
      echo "[notify.sh DEBUG] No port found in registry for PID=$pid or PPID=$ppid_of_match" >&2
    else
      echo "[notify.sh DEBUG] CLAUDECODE=1 not found on PID=$pid" >&2
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    echo "[notify.sh DEBUG] Walking to next PID=$pid" >&2
  done
  echo "[notify.sh DEBUG] Exhausted process tree walk — no port found, returning failure" >&2
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
