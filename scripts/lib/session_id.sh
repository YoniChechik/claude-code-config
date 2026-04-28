#!/usr/bin/env bash
# Shared session identity helpers.
# Two contexts can't get session_id directly from a hook payload:
#   1. status_line.sh (its stdin payload has a different shape — but it does
#      contain session_id at the top level, so it extracts directly)
#   2. ci_watch_persistent.sh (detached process, no stdin payload — receives
#      SID8 as a CLI argument from the /ci skill)
# Hook scripts that need SID8 can use sid8_from_ppid() to look up the cache
# file written by session_start.sh, keyed by the Claude Code process PID.

# Extract SID8 from a hook JSON payload string.
# Usage: sid8=$(sid8_from_payload "$json")
sid8_from_payload() {
    local json="$1"
    local session_id
    session_id=$(printf '%s' "$json" | jq -r '.session_id // ""' 2>/dev/null)
    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        printf '%s' "${session_id:0:8}"
    else
        printf ''
    fi
}

# Look up SID8 from the PPID-keyed cache written by session_start.sh.
# Call from within a hook script; $PPID = the Claude Code process.
# Usage: sid8=$(sid8_from_ppid)
sid8_from_ppid() {
    local cache_file="$HOME/.claude/cache/ppid-session/$PPID"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    else
        printf ''
    fi
}
