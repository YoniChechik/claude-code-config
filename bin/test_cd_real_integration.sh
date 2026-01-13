#!/bin/bash

# Real integration test for cd session bug
# Tests actual claude CLI behavior with session resumption after cd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1: $2"; FAIL=$((FAIL + 1)); }

# Check if real claude CLI is available
if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found in PATH"
    exit 1
fi

# Test with real claude CLI
test_real_cd_session() {
    local raw1=$(mktemp)
    local raw2=$(mktemp)
    local schema='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'

    echo "Test 1: First command - cd /tmp"

    # First command: cd /tmp
    claude -p "cd /tmp" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw1" >/dev/null
    local exit1=$?

    if [ $exit1 -ne 0 ]; then
        test_fail "First cd command failed" "exit code $exit1"
        cat "$raw1" >&2
        rm -f "$raw1" "$raw2"
        return
    fi

    # Extract session_id
    local session_id
    session_id=$(grep '"subtype":"init"' "$raw1" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    if [ -z "$session_id" ]; then
        test_fail "First cd command" "no session_id found"
        echo "Raw output:" >&2
        cat "$raw1" >&2
        rm -f "$raw1" "$raw2"
        return
    fi

    echo "  Session ID: $session_id"

    # Extract cwd from structured_output
    local result1
    result1=$(grep '"type":"result"' "$raw1" | tail -1)
    local cwd1
    cwd1=$(echo "$result1" | jq -r '.structured_output.cwd // empty' 2>/dev/null)

    if [ "$cwd1" != "/tmp" ]; then
        test_fail "First cd command" "cwd should be /tmp, got '$cwd1'"
        echo "Result:" >&2
        echo "$result1" | jq . >&2
        rm -f "$raw1" "$raw2"
        return
    fi

    test_pass "First cd command succeeded (session: $session_id, cwd: $cwd1)"

    echo ""
    echo "Test 2: Second command - ls (resume session $session_id)"
    echo "  Waiting 1 second before resume..."
    sleep 1

    # Second command: ls (resume session)
    claude -p "ls" --resume "$session_id" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw2" >/dev/null
    local exit2=$?

    if [ $exit2 -ne 0 ]; then
        test_fail "Second ls command after cd" "exit code $exit2"
        echo "Raw output:" >&2
        cat "$raw2" >&2
        rm -f "$raw1" "$raw2"
        return
    fi

    # Check for result
    local result2
    result2=$(grep '"type":"result"' "$raw2" | tail -1)

    if [ -z "$result2" ]; then
        test_fail "Second ls command after cd" "no result found"
        echo "Raw output:" >&2
        cat "$raw2" >&2
        rm -f "$raw1" "$raw2"
        return
    fi

    test_pass "Second ls command after cd succeeded"

    rm -f "$raw1" "$raw2"
}

# Test: Multiple commands in sequence
test_multiple_commands_sequence() {
    local raw=$(mktemp)
    local schema='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'
    local session_id=""

    # Command 1: cd /tmp
    claude -p "cd /tmp" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw" >/dev/null
    if [ $? -ne 0 ]; then
        test_fail "Multiple commands: cd /tmp failed" "exit code $?"
        rm -f "$raw"
        return
    fi

    session_id=$(grep '"subtype":"init"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
    if [ -z "$session_id" ]; then
        test_fail "Multiple commands: no session_id" ""
        rm -f "$raw"
        return
    fi

    sleep 1

    # Command 2: echo test
    rm -f "$raw"
    claude -p "echo test" --resume "$session_id" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw" >/dev/null
    if [ $? -ne 0 ]; then
        test_fail "Multiple commands: echo test failed" "exit code $?"
        rm -f "$raw"
        return
    fi

    sleep 1

    # Command 3: cd /home
    rm -f "$raw"
    claude -p "cd /home" --resume "$session_id" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw" >/dev/null
    if [ $? -ne 0 ]; then
        test_fail "Multiple commands: cd /home failed" "exit code $?"
        rm -f "$raw"
        return
    fi

    sleep 1

    # Command 4: ls
    rm -f "$raw"
    claude -p "ls" --resume "$session_id" --output-format stream-json --verbose --json-schema "$schema" 2>"$raw" >/dev/null
    if [ $? -ne 0 ]; then
        test_fail "Multiple commands: final ls failed" "exit code $?"
        rm -f "$raw"
        return
    fi

    test_pass "Multiple commands sequence: cd → echo → cd → ls all succeeded"
    rm -f "$raw"
}

echo "Real Claude CLI Integration Tests"
echo "=================================="
echo ""

test_real_cd_session
echo ""
test_multiple_commands_sequence

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
