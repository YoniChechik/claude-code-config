#!/bin/bash

# Diagnostic test that mimics exactly what ccui.sh does
# This will help us see where the "nothing happens" bug occurs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================="
echo "CCUI Diagnostic Test"
echo "========================================="
echo "This test mimics the exact ccui.sh workflow"
echo ""

# Source autosuggest (in case it's needed)
source "$CLAUDE_DIR/bin/autosuggest.sh" 2>/dev/null || true

# Mimic ccui.sh variables
SESSION_ID=""
LAST_MS=0
MODEL=""
SESSION_CWD=""

# Mimic run_claude function
run_claude_test() {
    local prompt="$1"
    local raw
    raw=$(mktemp)
    local schema='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'
    local args=(-p "$prompt" --output-format stream-json --verbose --json-schema "$schema")

    echo "  Running claude with prompt: $prompt"
    [ -n "$SESSION_ID" ] && echo "  Using --resume $SESSION_ID" && args+=(--resume "$SESSION_ID")

    [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ] && \
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")

    # Run claude and capture output
    claude "${args[@]}" 2>&1 | stdbuf -oL tee "$raw" | \
        stdbuf -oL jq -r --unbuffered -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null | \
        while IFS= read -r line; do
            case "$line" in
                TEXT:*) printf "%s" "${line#TEXT:}" | sed 's/@@NEWLINE@@/\n/g' ;;
                SUB:*)  printf "\033[90m│\033[0m  %s\n" "${line#SUB:}" ;;
                LINE:*) printf "%s\n" "${line#LINE:}" ;;
                JSON:*) printf "%s\n" "${line#JSON:}" ;;
            esac
        done

    # Extract session_id on first call
    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(grep '"subtype":"init"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
        echo "  [DEBUG] Extracted SESSION_ID: $SESSION_ID"

        # Verify it's not from hook_response
        local hook_session=$(grep '"subtype":"hook_response"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
        if [ -n "$hook_session" ] && [ "$SESSION_ID" = "$hook_session" ]; then
            echo "  [ERROR] BUG DETECTED: Using hook_response session_id instead of init!"
        fi
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
    echo "  [DEBUG] Extracted SESSION_CWD from raw: $SESSION_CWD"

    rm -f "$raw"
}

echo "Test 1: cd /tmp"
echo "---------------"
run_claude_test "cd /tmp"
echo ""
echo "After cd:"
echo "  SESSION_ID=$SESSION_ID"
echo "  SESSION_CWD=$SESSION_CWD"
echo ""

if [ -z "$SESSION_ID" ]; then
    echo "✗ FAILED: No session_id extracted"
    exit 1
fi

if [ "$SESSION_CWD" != "/tmp" ]; then
    echo "✗ FAILED: SESSION_CWD should be /tmp, got: $SESSION_CWD"
    exit 1
fi

# Mimic the cd that ccui.sh does
if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
    echo "Changing shell directory to: $SESSION_CWD"
    cd "$SESSION_CWD" 2>/dev/null || true
    echo "Current directory: $(pwd)"
fi

echo ""
echo "Test 2: ls (after cd, with --resume)"
echo "------------------------------------"

# Check if session_id is still valid
if [ -z "$SESSION_ID" ]; then
    echo "✗ FAILED: SESSION_ID is empty before resume"
    exit 1
fi

echo "About to resume with SESSION_ID: $SESSION_ID"
run_claude_test "ls"
echo ""

echo "Test 3: pwd (second command after cd)"
echo "--------------------------------------"
run_claude_test "pwd"
echo ""

echo "========================================"
echo "✓ ALL TESTS PASSED"
echo "========================================"
echo ""
echo "Final state:"
echo "  SESSION_ID=$SESSION_ID"
echo "  SESSION_CWD=$SESSION_CWD"
echo "  MODEL=$MODEL"
echo "  Current dir: $(pwd)"
