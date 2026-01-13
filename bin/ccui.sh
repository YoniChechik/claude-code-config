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
PREV_CWD="$(pwd)"

# BUG FIX: Claude CLI session storage is directory-specific
# Sessions are stored at ~/.claude/projects/<encoded-directory>/<session-id>.jsonl
# When you cd to a different directory, --resume can't find the session because
# it only searches in the current directory's encoded path.
#
# SOLUTION: Create symlinks from target directory to source directory
# When user runs "cd /tmp" from /home/ubuntu/.claude:
# 1. Session is stored in ~/.claude/projects/-home-ubuntu--claude/SESSION.jsonl
# 2. We create symlink: ~/.claude/projects/-tmp/SESSION.jsonl -> original
# 3. Now --resume works from /tmp directory
#
# References:
# - https://github.com/anthropics/claude-code/issues/5768
# - https://github.com/anthropics/claude-code/issues/16103

dir_to_claude_path() {
    # Convert directory path to Claude's encoding format
    # Examples:
    #   /home/ubuntu/.claude -> -home-ubuntu--claude
    #   /tmp -> -tmp
    # Rule: Replace all / and . with -
    echo "$1" | tr '/.' '-'
}

create_session_symlink() {
    local session_id="$1"
    local source_dir="$2"
    local target_dir="$3"

    [ -z "$session_id" ] && return
    [ "$source_dir" = "$target_dir" ] && return

    local source_encoded
    local target_encoded
    source_encoded=$(dir_to_claude_path "$source_dir")
    target_encoded=$(dir_to_claude_path "$target_dir")

    local source_path="$HOME/.claude/projects/$source_encoded"
    local target_path="$HOME/.claude/projects/$target_encoded"

    # Create target directory if it doesn't exist
    mkdir -p "$target_path" 2>/dev/null || return

    # Create symlink for session file
    if [ -f "$source_path/$session_id.jsonl" ]; then
        ln -sf "$source_path/$session_id.jsonl" "$target_path/$session_id.jsonl" 2>/dev/null
    fi

    # Create symlink for session directory (if exists)
    if [ -d "$source_path/$session_id" ]; then
        ln -sf "$source_path/$session_id" "$target_path/$session_id" 2>/dev/null
    fi
}

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
        # Create symlink before cd so --resume will find the session
        create_session_symlink "$SESSION_ID" "$PREV_CWD" "$SESSION_CWD"

        cd "$SESSION_CWD" 2>/dev/null || true
        PREV_CWD="$SESSION_CWD"
    fi
done
