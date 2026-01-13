#!/bin/bash

# Test ccui.sh as an actual interactive REPL
# This test pipes commands to ccui.sh and monitors for hangs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================"
echo "CCUI Interactive REPL Test"
echo "========================================"
echo ""

# Create a named pipe for input
INPUT_PIPE=$(mktemp -u)
mkfifo "$INPUT_PIPE"

# Create output log
OUTPUT_LOG=$(mktemp)

echo "Starting ccui.sh..."
echo "Input pipe: $INPUT_PIPE"
echo "Output log: $OUTPUT_LOG"
echo ""

# Start ccui.sh with input from pipe, output to log
bash "$CLAUDE_DIR/bin/ccui.sh" < "$INPUT_PIPE" > "$OUTPUT_LOG" 2>&1 &
CCUI_PID=$!

echo "CCUI PID: $CCUI_PID"

# Function to send command and wait for response
send_command() {
    local cmd="$1"
    local timeout_sec="$2"
    local expect_pattern="$3"

    echo ""
    echo ">>> Sending: $cmd"

    # Send command to pipe
    echo "$cmd" > "$INPUT_PIPE" &
    SEND_PID=$!

    # Wait for command to be sent
    wait $SEND_PID 2>/dev/null || true

    # Wait for response with timeout
    local start_time=$(date +%s)
    local found=false

    while true; do
        # Check if pattern appears in output
        if grep -q "$expect_pattern" "$OUTPUT_LOG" 2>/dev/null; then
            echo "✓ Got response"
            found=true
            break
        fi

        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $timeout_sec ]; then
            echo "✗ TIMEOUT after ${timeout_sec}s - NO RESPONSE"
            break
        fi

        sleep 0.5
    done

    if [ "$found" = false ]; then
        echo "✗ BUG: Command got no response"
        return 1
    fi

    return 0
}

# Wait for initial prompt
sleep 2

# Test 1: cd /tmp
if ! send_command "cd /tmp" 30 "Changed to /tmp"; then
    echo ""
    echo "FAILED: cd /tmp got no response"
    kill $CCUI_PID 2>/dev/null || true
    rm -f "$INPUT_PIPE" "$OUTPUT_LOG"
    exit 1
fi

# Clear output log to check next response
sleep 2
> "$OUTPUT_LOG"

# Test 2: echo hello (after cd)
# THIS IS WHERE THE BUG OCCURS
if ! send_command "echo hello" 30 "hello"; then
    echo ""
    echo "========================================"
    echo "BUG CONFIRMED!"
    echo "========================================"
    echo "- cd /tmp worked"
    echo "- But 'echo hello' after cd got NO RESPONSE"
    echo "- ccui.sh became unresponsive"
    echo ""
    echo "Recent output:"
    tail -50 "$OUTPUT_LOG"

    kill $CCUI_PID 2>/dev/null || true
    rm -f "$INPUT_PIPE" "$OUTPUT_LOG"
    exit 2
fi

# Clear and test more commands
sleep 2
> "$OUTPUT_LOG"

# Test 3: pwd
if ! send_command "pwd" 30 "/tmp"; then
    echo ""
    echo "FAILED: pwd got no response"
    kill $CCUI_PID 2>/dev/null || true
    rm -f "$INPUT_PIPE" "$OUTPUT_LOG"
    exit 1
fi

echo ""
echo "========================================"
echo "✓ ALL TESTS PASSED"
echo "========================================"
echo "ccui.sh remained responsive after cd"

# Cleanup
echo "exit" > "$INPUT_PIPE" 2>/dev/null || true
sleep 1
kill $CCUI_PID 2>/dev/null || true
rm -f "$INPUT_PIPE" "$OUTPUT_LOG"

exit 0
