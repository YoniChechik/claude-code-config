#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input
source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_state.sh" 2>/dev/null || exit 0

ts_ms=${EPOCHREALTIME/[.,]/}
ts_ms=${ts_ms:0:13}

mapfile -d '' fields < <(printf '%s' "$input" | jq -j --arg op record --argjson ts_ms "$ts_ms" \
    -f "$HOOK_DIR/_probe_ledger.jq" 2>/dev/null)
((${#fields[@]} == 2)) || exit 0
session=${fields[0]}
record=${fields[1]}

if ! state_init "$session"; then
    hook_log "STATE_UNTRUSTED: $STATE_ERR"
    exit 0
fi

sha=$(printf '%s' "$input" | jq -j --arg op hash --argjson ts_ms 0 -f "$HOOK_DIR/_probe_ledger.jq" 2>/dev/null | shasum -a 256)
sha=${sha%% *}
[[ $sha =~ ^[0-9a-f]{64}$ ]] && record="${record%\}},\"out_sha256\":\"$sha\"}"

ledger_append "$record" || hook_log "error: cannot record probe session=$session"
exit 0
