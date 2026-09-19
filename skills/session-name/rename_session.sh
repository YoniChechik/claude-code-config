#!/usr/bin/env bash
# Extracted from session-name/SKILL.md's pure-bash steps (sanitize, no-op
# check, atomic write). The no-op decision and the subagent-confirmation gate
# stay agent-level instructions in the SKILL.md — they need judgment and a
# tool call (SendMessage) a shell script can't make, so this script only
# resolves a candidate name and, separately, writes a confirmed one.
#
# Usage:
#   rename_session.sh resolve <candidate-name>
#     Sanitizes+caps <candidate-name> (via the shared _notify.sh contract) and
#     prints it. Exit 0 if it differs from the currently stored name (the
#     caller should proceed to the subagent gate, then `write`); exit 10 if
#     it's unchanged (no-op — the caller should report it and stop, not
#     write or re-trigger any rename step); exit 1 if it sanitizes to empty.
#   rename_session.sh write <name>
#     Atomically writes <name> as the new stored session name.
#
# SESSION_ID is read from CLAUDE_CODE_SESSION_ID, matching Claude Code's own
# convention. Another tool without that exact variable can export
# AGENT_SESSION_ID instead to get the same durable, pollable sidecar-file
# behavior (used by status_line.sh); a tool with its own simpler native
# session-naming mechanism and no equivalent poller may not need this sidecar
# file at all, and can skip this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${AGENT_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    echo "Error: no session id (CLAUDE_CODE_SESSION_ID or AGENT_SESSION_ID) is set; cannot set a session name." >&2
    exit 1
fi

# shellcheck source=../../scripts/_notify.sh
source "${SCRIPT_DIR}/../../scripts/_notify.sh"

MODE="${1:-}"
CANDIDATE="${2:-}"

case "$MODE" in
    resolve)
        if [[ -z "$CANDIDATE" ]]; then
            echo "Usage: $0 resolve <candidate-name>" >&2
            exit 2
        fi
        NAME=$(_sanitize_and_cap "$CANDIDATE")
        if [[ -z "$NAME" ]]; then
            echo "Error: the proposed session name is empty after sanitizing; nothing written." >&2
            exit 1
        fi
        STORED_NAME=$(_session_name_read "$SESSION_ID")
        echo "$NAME"
        if [[ "$NAME" == "$STORED_NAME" ]]; then
            exit 10
        fi
        exit 0
        ;;
    write)
        if [[ -z "$CANDIDATE" ]]; then
            echo "Usage: $0 write <name>" >&2
            exit 2
        fi
        DEST="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_${SESSION_ID}"
        tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_XXXXXX") || {
            echo "Error: could not create the temp file for the session name." >&2
            exit 1
        }
        if ! printf '%s' "$CANDIDATE" >"$tmp" || ! mv -f "$tmp" "$DEST"; then
            rm -f "$tmp"
            echo "Error: could not store the session name at $DEST." >&2
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 resolve|write <name>" >&2
        exit 2
        ;;
esac
