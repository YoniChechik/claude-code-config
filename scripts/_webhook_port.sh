#!/usr/bin/env bash
#
# _webhook_port.sh — Shared helper to resolve the Claude webhook port.
#
# Usage:
#   source ~/.claude/scripts/_webhook_port.sh
#   port=$(find_claude_port)   # returns port on stdout, or exits 1
#
# The function checks $CLAUDE_WEBHOOK_PORT first (env var override),
# then falls back to the ancestry-walk algorithm.
#

_WEBHOOK_PORT_NODE=$(which node 2>/dev/null || echo /usr/local/bin/node)

find_claude_port() {
  # --- Fast path: env var override (set by CI watcher launcher, etc.) ---
  if [ -n "${CLAUDE_WEBHOOK_PORT:-}" ]; then
    echo "$CLAUDE_WEBHOOK_PORT"
    return 0
  fi

  # --- Slow path: ancestry walk ---
  local registry="$HOME/.claude_session_id_to_port"
  [ -f "$registry" ] || return 1

  local claude_pids
  claude_pids=$("$_WEBHOOK_PORT_NODE" -e "
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

  # Use while-read instead of `for x in $var` because zsh does not
  # perform word-splitting on unquoted scalars by default — the for
  # loop would iterate once with the entire multi-line string as a
  # single value, breaking the ancestry walk.
  while IFS= read -r claude_pid; do
    [ -z "$claude_pid" ] && continue
    ps -p "$claude_pid" > /dev/null 2>&1 || continue

    # Walk Claude's ancestry, find first PID in our ordered list
    local cpid="$claude_pid"
    local found_ancestor=0
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
          found_ancestor=1
          break  # break out of for-anc loop
        fi
        idx=$((idx + 1))
      done
      # If we found a common ancestor, stop walking this claude_pid's ancestry
      [ "$found_ancestor" -eq 1 ] && break
      cpid=$(ps -p "$cpid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$cpid" ] && break
    done
  done <<< "$claude_pids"

  if [ -n "$best_claude_pid" ]; then
    local port
    port=$("$_WEBHOOK_PORT_NODE" -e "
      const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
      process.stdout.write(String(r[process.argv[2]] || ''));
    " -- "$registry" "$best_claude_pid" 2>/dev/null)
    if [ -n "$port" ] && [ "$port" != "undefined" ]; then
      echo "$port"
      return 0
    fi
  fi

  return 1
}
