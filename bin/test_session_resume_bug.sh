#!/bin/bash

# Comprehensive test to reproduce the critical --resume bug
# This test proves that --resume creates a NEW session instead of resuming existing ones

set -e

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

echo "========================================="
echo "Session Resume Bug Reproduction Test"
echo "========================================="
echo ""

# Check if claude CLI is available
if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found"
    exit 1
fi

SCHEMA='{"type":"object","properties":{"cwd":{"type":"string"},"response":{"type":"string"}},"required":["cwd","response"]}'

echo "Test 1: Create initial session"
echo "------------------------------"

RAW1=$(mktemp)
claude -p "echo test1" --output-format stream-json --verbose --json-schema "$SCHEMA" 2>"$RAW1" >/dev/null

SESSION1=$(grep -E '"subtype":"(init|hook_response)"' "$RAW1" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION1" ]; then
    test_fail "Failed to create initial session"
    rm -f "$RAW1"
    exit 1
fi

echo "  Created session: $SESSION1"
test_pass "Initial session created"

echo ""
echo "Test 2: Check session directory"
echo "--------------------------------"

SESSION_DIR="$HOME/.claude/session-env/$SESSION1"
if [ ! -d "$SESSION_DIR" ]; then
    test_fail "Session directory doesn't exist: $SESSION_DIR"
else
    test_pass "Session directory exists"

    FILE_COUNT=$(find "$SESSION_DIR" -type f | wc -l)
    echo "  Files in session directory: $FILE_COUNT"

    if [ "$FILE_COUNT" -eq 0 ]; then
        test_fail "Session directory is EMPTY (no persistence)"
    else
        test_pass "Session directory contains $FILE_COUNT file(s)"
    fi
fi

echo ""
echo "Test 3: Resume session with --resume flag"
echo "------------------------------------------"

echo "  Waiting 2 seconds before resume..."
sleep 2

RAW2=$(mktemp)
claude -p "echo test2" --resume "$SESSION1" --output-format stream-json --verbose --json-schema "$SCHEMA" 2>"$RAW2" >/dev/null

SESSION2=$(grep -E '"subtype":"(init|hook_response)"' "$RAW2" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION2" ]; then
    test_fail "No session_id in resume response"
    rm -f "$RAW1" "$RAW2"
    exit 1
fi

echo "  Original session: $SESSION1"
echo "  Resume session:   $SESSION2"
echo ""

if [ "$SESSION1" = "$SESSION2" ]; then
    test_pass "Session was resumed correctly (same ID)"
else
    test_fail "BUG CONFIRMED: --resume created NEW session instead of resuming"
    echo ""
    echo "  This is the root cause of ccui.sh becoming unresponsive!"
fi

echo ""
echo "Test 4: Multiple resume attempts"
echo "---------------------------------"

for i in {1..3}; do
    sleep 1
    RAW3=$(mktemp)
    claude -p "echo test$i" --resume "$SESSION1" --output-format stream-json --verbose --json-schema "$SCHEMA" 2>"$RAW3" >/dev/null

    SESSION3=$(grep -E '"subtype":"(init|hook_response)"' "$RAW3" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    if [ "$SESSION1" != "$SESSION3" ]; then
        test_fail "Resume attempt $i: NEW session created ($SESSION3)"
    else
        test_pass "Resume attempt $i: Same session maintained"
    fi

    rm -f "$RAW3"
done

echo ""
echo "Test 5: Resume with --append-system-prompt"
echo "-------------------------------------------"

if [ -f "$HOME/.claude/main_appended_system_prompt.md" ]; then
    sleep 1
    RAW4=$(mktemp)
    claude -p "echo test_append" --resume "$SESSION1" \
        --output-format stream-json --verbose --json-schema "$SCHEMA" \
        --append-system-prompt "$(cat "$HOME/.claude/main_appended_system_prompt.md")" \
        2>"$RAW4" >/dev/null

    SESSION4=$(grep -E '"subtype":"(init|hook_response)"' "$RAW4" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    if [ "$SESSION1" != "$SESSION4" ]; then
        test_fail "Resume with append-system-prompt: NEW session created"
    else
        test_pass "Resume with append-system-prompt: Same session maintained"
    fi

    rm -f "$RAW4"
else
    echo "  Skipping: main_appended_system_prompt.md not found"
fi

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

rm -f "$RAW1" "$RAW2"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "BUG CONFIRMED!"
    echo "The --resume flag does NOT work correctly."
    echo "This makes ccui.sh unresponsive after the first command."
    echo ""
    echo "Expected: --resume should use the same session_id"
    echo "Actual: --resume creates a NEW session with different ID"
    exit 1
else
    echo ""
    echo "All tests passed! Session resume is working correctly."
    exit 0
fi
