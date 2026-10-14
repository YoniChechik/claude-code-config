#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../scripts/_notify.sh
source "${SCRIPT_DIR}/../../scripts/_notify.sh"
# shellcheck source-path=SCRIPTDIR source=../../scripts/_state.sh
source "${SCRIPT_DIR}/../../scripts/_state.sh"

usage() {
    echo "Usage: $0 <name> [--done '<predicate item>']..." >&2
    exit 2
}

[[ -n "${1:-}" ]] || usage
RAW_NAME="$1"
shift
ITEMS=()
while (($#)); do
    case "$1" in
    --done)
        [[ -n "${2:-}" ]] || usage
        ITEMS+=("$2")
        shift 2
        ;;
    *) usage ;;
    esac
done

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${AGENT_SESSION_ID:-}}"
[[ -n "$SESSION_ID" ]] || {
    echo "Error: no session id (CLAUDE_CODE_SESSION_ID or AGENT_SESSION_ID) set." >&2
    exit 1
}

NAME=$(_sanitize_and_cap "$RAW_NAME")
[[ -n "$NAME" ]] || {
    echo "Error: name is empty after sanitizing; nothing written." >&2
    exit 1
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

record_predicate() {
    ((${#ITEMS[@]})) || return 0
    state_init "$SESSION_ID" || fail "state directory is untrusted: $STATE_ERR"
    local items sha last
    items=$(jq -nc '$ARGS.positional | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' --args "${ITEMS[@]}")
    [[ $(jq 'length' <<<"$items") -gt 0 ]] || fail "the predicate is empty."
    sha=$(printf '%s' "$items" | shasum -a 256 | cut -d' ' -f1)
    last=$(jq -Rr 'fromjson? | select(type == "object" and .kind == "predicate") | .sha256' "$STATE_DIR/ledger.jsonl" 2>/dev/null | tail -n 1 || true)
    [[ "$last" == "$sha" ]] && return 0
    ledger_append "$(jq -nc --argjson items "$items" --arg sha "$sha" '{kind: "predicate", items: $items, sha256: $sha}')" ||
        fail "could not write the session ledger."
}

if [[ "$NAME" == "$(_session_name_read "$SESSION_ID")" ]]; then
    record_predicate
    exit 0
fi

DEST="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_${SESSION_ID}"
tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_XXXXXX") || fail "could not create temp file."
if ! printf '%s' "$NAME" >"$tmp" || ! mv -f "$tmp" "$DEST"; then
    rm -f "$tmp"
    fail "could not store the session name at $DEST."
fi
echo "$NAME"
record_predicate

[[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]] || exit 0

GUID="${ITERM_SESSION_ID#*:}"

TTY_DEVICE=$(
    osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if unique ID of s is "$GUID" then return tty of s
            end repeat
        end repeat
    end repeat
end tell
APPLESCRIPT
)
[[ -z "$TTY_DEVICE" ]] || printf '\e]1;%s\a' "$NAME" >"$TTY_DEVICE"

CMD="${NATIVE_RENAME_CMD:-/rename}"
ESC="${NAME//\\/\\\\}"
ESC="${ESC//\"/\\\"}"
osascript <<APPLESCRIPT
on writeTo(txt, nl)
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if unique ID of s is "$GUID" then
                        tell s to write text txt newline nl
                        return
                    end if
                end repeat
            end repeat
        end repeat
    end tell
end writeTo
writeTo("$CMD $ESC", false)
delay 0.3
writeTo("", true)
APPLESCRIPT
