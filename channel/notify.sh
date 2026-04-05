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

  # Build ordered ancestry list: index 0 = $$, index 1 = parent, etc.
  local my_ancestors_ordered=()
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    my_ancestors_ordered+=("$pid")
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done

  local best_claude_pid=""
  local best_depth=99999

  for claude_pid in $claude_pids; do
    ps -p "$claude_pid" > /dev/null 2>&1 || continue

    # Walk Claude's ancestry, find first PID in our ordered list
    local cpid="$claude_pid"
    while [ "$cpid" -gt 1 ]; do
      # Find index of cpid in my_ancestors_ordered
      local idx=0
      for anc in "${my_ancestors_ordered[@]}"; do
        if [ "$anc" = "$cpid" ]; then
          # Found common ancestor at depth $idx
          if [ "$idx" -lt "$best_depth" ]; then
            best_depth="$idx"
            best_claude_pid="$claude_pid"
          fi
          break 2  # break inner while
        fi
        idx=$((idx + 1))
      done
      cpid=$(ps -p "$cpid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$cpid" ] && break
    done
  done

  if [ -n "$best_claude_pid" ]; then
    local port
    port=$("$NODE" -e "
      const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
      process.stdout.write(String(r[process.argv[2]] || ''));
    " -- "$registry" "$best_claude_pid" 2>/dev/null)
    if [ -n "$port" ] && [ "$port" != "undefined" ]; then
      echo "$port"
      return 0
    fi
  fi

  echo "notify.sh: no active Claude webhook session found" >&2
  return 1
}

MESSAGE="$*"
PORT=$(find_claude_port) || { echo "notify.sh: no active Claude webhook session found" >&2; exit 1; }
RESPONSE=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "$MESSAGE")
if [ "$RESPONSE" = "ok" ]; then
  echo "Notified Claude session on port $PORT"
else
  echo "notify.sh: unexpected response: $RESPONSE" >&2
  exit 1
fi
