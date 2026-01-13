#!/bin/bash

# Real integration test for cd session bug
# Uses actual claude CLI to test session behavior

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

# Check if claude CLI is available
if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found in PATH"
    exit 1
fi

# Test with debugger agent (minimal subagent for testing)
SCHEMA='{"type":"object","properties":{"cwd":{"type":"string","description":"Current working directory path"},"response":{"type":"string","description":"Response to user"}},"required":["cwd","response"]}'

# Test 1: Basic StructuredOutput - single command
test_structured_output_single() {
    local raw=$(mktemp)
    local session_id=""

    # First command
    claude -p "Return StructuredOutput with cwd=$(pwd) and response='Test 1 success'" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/agents/debugger_appended_system_prompt.md" 2>/dev/null || echo '')" \
        2>"$raw" >/dev/null

    # Extract session_id
    session_id=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)

    if [ -n "$session_id" ]; then
        test_pass "Single command: session created ($session_id)"
    else
        test_fail "Single command: no session_id"
    fi

    rm -f "$raw"
}

# Test 2: StructuredOutput with --resume
test_structured_output_resume() {
    local raw=$(mktemp)
    local session_id=""

    # First command
    claude -p "Return StructuredOutput with cwd=$(pwd) and response='Command 1'" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/agents/debugger_appended_system_prompt.md" 2>/dev/null || echo '')" \
        2>"$raw" >/dev/null

    session_id=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)

    if [ -z "$session_id" ]; then
        test_fail "Resume test: no session_id from first command"
        rm -f "$raw"
        return
    fi

    # Second command with --resume
    rm -f "$raw"
    claude -p "Return StructuredOutput with cwd=$(pwd) and response='Command 2'" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --resume "$session_id" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/agents/debugger_appended_system_prompt.md" 2>/dev/null || echo '')" \
        2>"$raw" >/dev/null

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Check if we got a result
        local result
        result=$(grep '"type":"result"' "$raw" | tail -1)
        if [ -n "$result" ]; then
            test_pass "Resume test: second command succeeded"
        else
            test_fail "Resume test: second command no result"
        fi
    else
        test_fail "Resume test: second command failed (exit $exit_code)"
    fi

    rm -f "$raw"
}

# Test 3: Simulate ccui.sh behavior - cd then another command
test_ccui_simulation() {
    local raw=$(mktemp)
    local session_id=""
    local session_cwd=""

    # First: simulate cd /tmp
    claude -p "cd /tmp" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")" \
        2>"$raw" >/dev/null

    session_id=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)

    if [ -z "$session_id" ]; then
        test_fail "ccui simulation: no session_id from cd"
        rm -f "$raw"
        return
    fi

    # Extract cwd from structured output
    local result
    result=$(grep '"type":"result"' "$raw" | tail -1)
    if [ -n "$result" ]; then
        session_cwd=$(echo "$result" | jq -r '.structured_output.cwd // empty' 2>/dev/null)
    fi

    if [ -z "$session_cwd" ]; then
        test_fail "ccui simulation: cd response missing cwd"
        rm -f "$raw"
        return
    fi

    # Simulate directory change in shell (what ccui.sh does)
    # We don't actually cd, we just track the cwd value

    # Second: ls command with --resume
    rm -f "$raw"
    claude -p "ls" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --resume "$session_id" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/main_appended_system_prompt.md")" \
        2>"$raw" >/dev/null

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Check if we got a result
        result=$(grep '"type":"result"' "$raw" | tail -1)
        if [ -n "$result" ]; then
            test_pass "ccui simulation: ls after cd succeeded (session_id: ${session_id:0:8}...)"
        else
            test_fail "ccui simulation: ls after cd no result"
        fi
    else
        test_fail "ccui simulation: ls after cd failed (exit $exit_code)"
        # Show error output for debugging
        echo "  Error output from second command:"
        cat "$raw" | head -20
    fi

    rm -f "$raw"
}

# Test 4: Check if session persists across multiple StructuredOutput calls
test_multiple_structured_outputs() {
    local raw=$(mktemp)
    local session_id=""

    # Command 1
    claude -p "First command" \
        --output-format stream-json \
        --verbose \
        --json-schema "$SCHEMA" \
        --append-system-prompt "$(cat "$CLAUDE_DIR/agents/debugger_appended_system_prompt.md" 2>/dev/null || echo '')" \
        2>"$raw" >/dev/null

    session_id=$(head -1 "$raw" | jq -r '.session_id // empty' 2>/dev/null)

    if [ -z "$session_id" ]; then
        test_fail "Multiple StructuredOutputs: no session_id"
        rm -f "$raw"
        return
    fi

    # Commands 2, 3, 4 with --resume
    local success_count=0
    for i in 2 3 4; do
        rm -f "$raw"
        claude -p "Command $i" \
            --output-format stream-json \
            --verbose \
            --json-schema "$SCHEMA" \
            --resume "$session_id" \
            --append-system-prompt "$(cat "$CLAUDE_DIR/agents/debugger_appended_system_prompt.md" 2>/dev/null || echo '')" \
            2>"$raw" >/dev/null

        if [ $? -eq 0 ]; then
            local result
            result=$(grep '"type":"result"' "$raw" | tail -1)
            if [ -n "$result" ]; then
                success_count=$((success_count + 1))
            fi
        else
            break
        fi
    done

    if [ $success_count -eq 3 ]; then
        test_pass "Multiple StructuredOutputs: 3 resume commands succeeded"
    else
        test_fail "Multiple StructuredOutputs: only $success_count/3 succeeded"
    fi

    rm -f "$raw"
}

echo "Running real claude CLI session tests..."
echo ""
echo "These tests use the actual claude CLI with StructuredOutput"
echo ""

test_structured_output_single
test_structured_output_resume
test_multiple_structured_outputs
test_ccui_simulation

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
