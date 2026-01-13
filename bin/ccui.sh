#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$CLONE_ROOT/bin/autosuggest.sh" ]; then
    CLAUDE_DIR="$CLONE_ROOT"
else
    CLAUDE_DIR="$HOME/.claude"
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not installed" >&2
    echo "" >&2
    echo "To install jq on Ubuntu without sudo:" >&2
    echo "  apt update && apt install -y jq" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CLAUDE_DIR/bin/autosuggest.sh"

# shellcheck source=/dev/null
source "$CLAUDE_DIR/bin/val.sh"
validate_environment

SESSION_ID=""
LAST_MS=0
MODEL=""
SESSION_CWD=""

run_claude() {
    local raw
    raw=$(mktemp)
    local schema='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'
    local args=(-p "$1" --output-format stream-json --verbose --json-schema "$schema")

    [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")

    [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ] && \
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")

    trap 'echo -e "\n\033[90m[Stopped]\033[0m"' INT

    while IFS= read -r line; do
        case "$line" in
            TEXT:*) printf "%s" "${line#TEXT:}" | sed 's/@@NEWLINE@@/\n/g' ;;
            SUB:*)  printf "\033[90m│\033[0m  %s\n" "${line#SUB:}" ;;
            LINE:*) printf "%s\n" "${line#LINE:}" ;;
            JSON:*) printf "%s\n" "${line#JSON:}" ;;
        esac
    done < <(stdbuf -oL claude "${args[@]}" 2>&1 | stdbuf -oL tee "$raw" | \
        stdbuf -oL jq -r --unbuffered -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    trap - INT

    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(grep '"subtype":"init"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
    fi

    local model
    model=$(grep '"subtype":"init"' "$raw" | jq -r '.model // empty' 2>/dev/null)
    [ -n "$model" ] && MODEL="$model"

    local result
    result=$(grep '"type":"result"' "$raw" | tail -1)
    [ -n "$result" ] && LAST_MS=$(echo "$result" | jq -r '.duration_ms // 0')

    # Extract cwd from structured_output (cannot be done in while loop due to subshell)
    local cwd
    cwd=$(echo "$result" | jq -r '.structured_output.cwd // empty' 2>/dev/null)
    [ -n "$cwd" ] && SESSION_CWD="$cwd"

    rm -f "$raw"
}

show_prompt() {
    printf "\033[33m%s" "$(pwd)"
    if [ "$LAST_MS" -gt 0 ]; then
        local sec
        sec=$(awk "BEGIN {printf \"%.1f\", $LAST_MS/1000}")
        printf " [%ss │ %s]" "$sec" "$MODEL"
    fi
    printf "\033[0m\n"
}

echo "cc - Claude Code REPL (Ctrl+C to stop, Ctrl+D to exit)"
echo ""

while true; do
    show_prompt

    input=$(read_with_autosuggest)
    ret=$?
    [[ $ret -eq 1 ]] && break
    [[ $ret -eq 2 ]] && continue

    if [[ -z "$input" ]]; then
        continue
    fi

    run_claude "$input"

    if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
        cd "$SESSION_CWD" 2>/dev/null || true
    fi
done
