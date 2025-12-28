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

# Execute Claude with user prompt and display streaming output
run_claude() {
    local raw=$(mktemp)
    local args=(-p "$1" --output-format stream-json --verbose)

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

echo "cc - Claude Code REPL (Ctrl+C to stop, Ctrl+D to exit)"
echo ""

# Main REPL loop
while true; do
    show_prompt

    # Read user input with readline support (Ctrl+D exits)
    read -r -e -p "> " input || break

    # Skip empty input
    if [[ -z "$input" ]]; then
        continue
    fi

    # Save to bash history
    history -s "$input"

    # Execute Claude with user input
    run_claude "$input"
done
