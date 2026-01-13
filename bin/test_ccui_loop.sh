#!/bin/bash

# Minimal test to reproduce ccui.sh loop behavior with cd commands
# This simulates the exact flow of ccui.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SESSION_ID=""
SESSION_CWD=""
SCHEMA='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'

run_claude() {
    local prompt="$1"
    local raw=$(mktemp)
    local args=(-p "$prompt" --output-format stream-json --verbose --json-schema "$SCHEMA")

    [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")

    [ -f "$CLAUDE_DIR/main_appended_system_prompt.md" ] && \
        args+=(--append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")")

    echo "Running: claude ${args[@]}" >&2
    echo "Prompt: $prompt" >&2

    # Run claude and capture output (provide stdin, capture both stdout and stderr)
    echo "$prompt" | timeout 30s claude "${args[@]}" 2>&1 | tee "$raw" >/dev/null
    local exit_code=${PIPESTATUS[1]}

    echo "Exit code: $exit_code" >&2

    if [ $exit_code -ne 0 ]; then
        echo "ERROR: claude command failed" >&2
        cat "$raw" >&2
        rm -f "$raw"
        return 1
    fi

    # Extract session_id on first call
    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(grep '"subtype":"init"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
        echo "Session ID: $SESSION_ID" >&2
    fi

    # Extract cwd from structured output
    local result
    result=$(grep '"type":"result"' "$raw" | tail -1)
    if [ -n "$result" ]; then
        SESSION_CWD=$(echo "$result" | jq -r '.structured_output.cwd // empty' 2>/dev/null)
        echo "Session CWD: $SESSION_CWD" >&2

        # Extract and show response
        local response
        response=$(echo "$result" | jq -r '.structured_output.response // empty' 2>/dev/null)
        if [ -n "$response" ]; then
            echo "Response: $response" >&2
        fi
    fi

    rm -f "$raw"
    return 0
}

echo "=== Test 1: cd /tmp ==="
run_claude "cd /tmp"
if [ $? -ne 0 ]; then
    echo "FAIL: First cd command failed"
    exit 1
fi

if [ "$SESSION_CWD" != "/tmp" ]; then
    echo "FAIL: SESSION_CWD not updated to /tmp (got: $SESSION_CWD)"
    exit 1
fi

echo ""
echo "=== Test 2: ls (after cd) ==="
run_claude "ls"
if [ $? -ne 0 ]; then
    echo "FAIL: ls command after cd failed"
    exit 1
fi

echo ""
echo "=== Test 3: cd /home/ubuntu ==="
run_claude "cd /home/ubuntu"
if [ $? -ne 0 ]; then
    echo "FAIL: Second cd command failed"
    exit 1
fi

if [ "$SESSION_CWD" != "/home/ubuntu" ]; then
    echo "FAIL: SESSION_CWD not updated to /home/ubuntu (got: $SESSION_CWD)"
    exit 1
fi

echo ""
echo "=== Test 4: pwd (after second cd) ==="
run_claude "pwd"
if [ $? -ne 0 ]; then
    echo "FAIL: pwd command after second cd failed"
    exit 1
fi

echo ""
echo "SUCCESS: All tests passed"
echo "Session remained responsive after multiple cd commands and StructuredOutput calls"
