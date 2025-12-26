#!/bin/bash

# For testing in clones, use local directory if available, otherwise fall back to ~/.claude
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

source "$CLAUDE_DIR/bin/autosuggest.sh"

source "$CLAUDE_DIR/bin/val.sh"
validate_environment

SESSION_ID=""
TOTAL_COST=0
TOTAL_IN=0
TOTAL_OUT=0
LAST_MS=0
MODEL=""

run_claude() {
    local raw=$(mktemp)
    local args=(-p "$1" --output-format stream-json --verbose)
    [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")
    [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ] && \
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")

    trap 'echo -e "\n\033[90m[Stopped]\033[0m"' INT

    while IFS= read -r line; do
        case "$line" in
            TEXT:*) printf "%s" "${line#TEXT:}" | sed 's/@@NEWLINE@@/\n/g' ;;
            SUB:*)  printf "\033[90m│\033[0m  %s\n" "${line#SUB:}" ;;
            LINE:*) printf "%s\n" "${line#LINE:}" ;;
        esac
    done < <(stdbuf -oL claude "${args[@]}" 2>&1 | stdbuf -oL tee "$raw" | \
        stdbuf -oL jq -r --unbuffered -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    trap - INT

    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)
    fi
    local model=$(grep '"subtype":"init"' "$raw" | jq -r '.model // empty' 2>/dev/null)
    [ -n "$model" ] && MODEL="$model"
    local result=$(grep '"type":"result"' "$raw" | tail -1)
    if [ -n "$result" ]; then
        local cost=$(echo "$result" | jq -r '.total_cost_usd // 0')
        if [ -n "$model" ]; then
            local in=$(echo "$result" | jq -r --arg m "$model" '.modelUsage[$m].inputTokens // 0')
            local out=$(echo "$result" | jq -r --arg m "$model" '.modelUsage[$m].outputTokens // 0')
            local cache=$(echo "$result" | jq -r --arg m "$model" '.modelUsage[$m].cacheReadInputTokens // 0')
            local cache_create=$(echo "$result" | jq -r --arg m "$model" '.modelUsage[$m].cacheCreationInputTokens // 0')
        else
            local in=$(echo "$result" | jq -r '.inputTokens // 0')
            local out=$(echo "$result" | jq -r '.outputTokens // 0')
            local cache=$(echo "$result" | jq -r '.cacheReadInputTokens // 0')
            local cache_create=$(echo "$result" | jq -r '.cacheCreationInputTokens // 0')
        fi
        LAST_MS=$(echo "$result" | jq -r '.duration_ms // 0')
        TOTAL_COST=$(awk "BEGIN {print $TOTAL_COST + $cost}")
        TOTAL_IN=$((TOTAL_IN + in + cache + cache_create))
        TOTAL_OUT=$((TOTAL_OUT + out))
    fi
    rm -f "$raw"
}

show_prompt() {
    printf "\033[33m%s@%s:%s" "$USER" "$(hostname -s)" "$(pwd)"
    if [ "$TOTAL_IN" -gt 0 ]; then
        local sec=$(awk "BEGIN {printf \"%.1f\", $LAST_MS/1000}")
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
    [[ $ret -eq 1 ]] && break     # Ctrl+D exits
    [[ $ret -eq 2 ]] && continue  # Ctrl+C cancels

    if [[ -z "$input" ]]; then
        continue
    fi
    [[ "$input" =~ ^(exit|quit)$ ]] && break
    history -s "$input"

    run_claude "$input"
done
