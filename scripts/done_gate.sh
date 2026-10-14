#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_state.sh"

usage() {
    cat >&2 <<'USAGE'
Usage:
  done_gate.sh check <item-index>   run a cmd: item of the current predicate and record the result
  done_gate.sh status               print the ledger of this session
USAGE
    exit 2
}

session=${CLAUDE_CODE_SESSION_ID:-${AGENT_SESSION_ID:-}}
[[ -n $session ]] || { echo "Error: no session id (CLAUDE_CODE_SESSION_ID) set." >&2; exit 1; }
state_init "$session" || { echo "Error: state directory is untrusted: $STATE_ERR" >&2; exit 1; }

cmd_check() {
    [[ ${1:-} =~ ^[0-9]+$ ]] || usage
    local index=$1 pred item cmd out rc sha out_sha
    ledger_latest predicate || { echo "Error: the session ledger is untrusted: $STATE_ERR" >&2; exit 1; }
    pred=$REPLY
    [[ -n $pred ]] || { echo "Error: no predicate recorded. Run: /session-name <label> --done '<item>' ..." >&2; exit 1; }
    item=$(jq -r --argjson i "$index" '.items[$i] // empty' <<<"$pred")
    [[ $item == cmd:* ]] || { echo "Error: item $index is not a cmd: item: ${item:-missing}" >&2; exit 1; }
    cmd=${item#cmd:}
    out=$(bash -c "$cmd" 2>&1 </dev/null)
    rc=$?
    printf '%s\n' "$out"
    sha=$(jq -r '.sha256' <<<"$pred")
    out_sha=$(printf '%s' "$out" | shasum -a 256 | cut -d' ' -f1)
    ledger_append "$(jq -nc --argjson i "$index" --arg p "$sha" --argjson e "$rc" --arg o "$out_sha" \
        '{kind: "check", item: $i, pred_sha: $p, exit: $e, out_sha256: $o}')" ||
        { echo "Error: could not write the ledger." >&2; exit 1; }
    echo "check $index: exit $rc"
    exit "$rc"
}

cmd_status() {
    [[ -f $STATE_DIR/ledger.jsonl ]] || { echo "ledger is empty"; return 0; }
    jq -Rr 'fromjson? | select(type == "object") | "\(if (.ts | type) == "number" then (.ts | todate) else (.ts // "") end) \(.kind) \(del(.ts, .kind) | tojson)"' "$STATE_DIR/ledger.jsonl"
}

case "${1:-}" in
    check) shift; cmd_check "$@" ;;
    status) cmd_status ;;
    *) usage ;;
esac
