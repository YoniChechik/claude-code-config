#!/bin/bash
# Claude Code REPL - Interactive command-line interface for Claude

CLAUDE_DIR="$HOME/.claude"

# Check for required jq dependency
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not installed" >&2
    echo "" >&2
    echo "To install jq on Ubuntu without sudo:" >&2
    echo "  apt update && apt install -y jq" >&2
    exit 1
fi

# Validate environment setup
source "$CLAUDE_DIR/bin/val.sh"
validate_environment

# Session tracking variables
SESSION_ID=""
LAST_MS=0
MODEL=""
SESSION_CWD=""

# Execute Claude with user prompt and display streaming output
run_claude() {
    local raw=$(mktemp)
    local schema='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'
    local args=(-p "$1" --output-format stream-json --verbose --json-schema "$schema")

    # Resume previous session if exists
    [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")

    # Append custom system prompt if available
    [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ] && \
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")

    # Handle Ctrl+C gracefully
    trap 'echo -e "\n\033[90m[Stopped]\033[0m"' INT

    # Stream and parse Claude output
    while IFS= read -r line; do
        case "$line" in
            TEXT:*) printf "%s" "${line#TEXT:}" | sed 's/@@NEWLINE@@/\n/g' ;;
            SUB:*)  printf "\033[90m│\033[0m  %s\n" "${line#SUB:}" ;;
            LINE:*) printf "%s\n" "${line#LINE:}" ;;
            JSON:*)
                json="${line#JSON:}"
                SESSION_CWD=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)
                ;;
        esac
    done < <(stdbuf -oL claude "${args[@]}" 2>&1 | stdbuf -oL tee "$raw" | \
        stdbuf -oL jq -r --unbuffered -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    trap - INT

    # Extract session ID from first response
    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)
    fi

    # Extract model information
    local model=$(grep '"subtype":"init"' "$raw" | jq -r '.model // empty' 2>/dev/null)
    [ -n "$model" ] && MODEL="$model"

    # Extract duration for prompt display
    local result=$(grep '"type":"result"' "$raw" | tail -1)
    [ -n "$result" ] && LAST_MS=$(echo "$result" | jq -r '.duration_ms // 0')

    rm -f "$raw"

    # Change to final session directory if captured
    if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
        cd "$SESSION_CWD" 2>/dev/null || true
    fi
}

# Display prompt with session statistics
show_prompt() {
    printf "\033[33m%s" "$(pwd)"
    if [ "$LAST_MS" -gt 0 ]; then
        local sec=$(awk "BEGIN {printf \"%.1f\", $LAST_MS/1000}")
        printf " [%ss │ %s]" "$sec" "$MODEL"
    fi
    printf "\033[0m\n"
}

# Read input with bracketed paste support
read_input() {
    local input=""
    local read_status

    echo -n '> ' >&2
    printf '\033[?2004h' >&2
    IFS= read -r input
    read_status=$?
    printf '\033[?2004l' >&2

    # Return immediately if read failed (EOF)
    [ $read_status -ne 0 ] && return $read_status

    # Handle multiline bracketed paste
    # If input starts with paste start marker, keep reading until end marker
    if [[ "$input" == $'\033[200~'* ]]; then
        # Strip the start marker
        input="${input#$'\033[200~'}"

        # Keep reading lines until we find the end marker
        while [[ "$input" != *$'\033[201~'* ]]; do
            local line=""
            IFS= read -r line || break
            input+=$'\n'"$line"
        done

        # Strip the end marker
        input="${input%$'\033[201~'}"
    fi

    echo "$input"
}

echo "cc - Claude Code REPL (Ctrl+C to stop, Ctrl+D to exit)"
echo ""

# Main REPL loop
while true; do
    show_prompt

    # Read user input with bracketed paste support (Ctrl+D exits)
    input=$(read_input) || break

    # Skip empty input
    if [[ -z "$input" ]]; then
        continue
    fi

    # Execute Claude with user input
    run_claude "$input"
done
