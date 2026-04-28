#!/usr/bin/env bash
# Shared session identity helpers.
# Two contexts can't get session_id directly from a hook payload:
#   1. status_line.sh (its stdin payload has a different shape)
#   2. ci_watch_persistent.sh (detached process, no stdin payload)
# Both use sid8_from_cwd() to look up the cache file written by session_start.sh.

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

# Look up SID8 from the cwd-session cache written by session_start.sh.
# Usage: sid8=$(sid8_from_cwd "/path/to/cwd")
sid8_from_cwd() {
    local cwd="$1"
    local cwd_hash
    cwd_hash=$(printf '%s' "$cwd" | shasum -a 1 | cut -c1-12)
    local cache_file="$HOME/.claude/cache/cwd-session/$cwd_hash"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    else
        printf ''
    fi
}
