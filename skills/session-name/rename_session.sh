#!/usr/bin/env bash
# Usage: rename_session.sh <name>
# Exit 0 = applied, 1 = error/empty name, 2 = usage, 10 = name unchanged (no-op).
# Env: CLAUDE_CODE_SESSION_ID (or AGENT_SESSION_ID); NATIVE_RENAME_CMD (default /rename).
set -euo pipefail

# Shared helpers: _sanitize_and_cap, _session_name_read
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/_notify.sh
source "${SCRIPT_DIR}/../../scripts/_notify.sh"

[[ -n "${1:-}" ]] || { echo "Usage: $0 <name>" >&2; exit 2; }
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${AGENT_SESSION_ID:-}}"
[[ -n "$SESSION_ID" ]] || { echo "Error: no session id (CLAUDE_CODE_SESSION_ID or AGENT_SESSION_ID) set." >&2; exit 1; }

# Step 1: sanitize + cap at 35 codepoints; empty result is an error
NAME=$(_sanitize_and_cap "$1")
[[ -n "$NAME" ]] || { echo "Error: name is empty after sanitizing; nothing written." >&2; exit 1; }

# Step 2: no-op if it already matches the stored name
if [[ "$NAME" == "$(_session_name_read "$SESSION_ID")" ]]; then
    echo "$NAME"
    exit 10
fi

# Step 3: atomic sidecar write (temp file + mv) so the status-line poller never sees a partial file
DEST="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_${SESSION_ID}"
tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_XXXXXX") || { echo "Error: could not create temp file." >&2; exit 1; }
if ! printf '%s' "$NAME" >"$tmp" || ! mv -f "$tmp" "$DEST"; then
    rm -f "$tmp"
    echo "Error: could not store the session name at $DEST." >&2
    exit 1
fi
echo "$NAME"

# Steps 4-5 only apply inside iTerm2
[[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]] || exit 0

# AppleScript's "unique ID" is the bare GUID; $ITERM_SESSION_ID has a "w2t1p0:" prefix to strip
GUID="${ITERM_SESSION_ID#*:}"

# Step 4: set the raw tab title (OSC 1). Bash tool stdout is a pipe, so write to the session's real tty device
TTY_DEVICE=$(osascript <<APPLESCRIPT
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
[[ -z "$TTY_DEVICE" ]] || printf '\e]1;%s\a' "$NAME" > "$TTY_DEVICE"

# Step 5: type "/rename <name>" into THIS session (by GUID, never the frontmost one), then send a
# lone CR as a separate write so Claude Code reads it as an Enter keypress, not pasted text.
# write text goes straight to the session's pty: no select/activate, so focus never changes.
# The GUID is re-resolved per write: loop refs are z-order indexes that shift if the user switches windows.
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
