#!/bin/bash

# Test non-interactive short prompt with bin/cc

echo "Testing bin/cc with short prompt..."

OUTPUT=$(printf "hi\nexit\n" | timeout 60 bin/cc 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 124 ]; then
    echo "FAIL: Timeout waiting for response"
    exit 1
fi

if [ -z "$OUTPUT" ]; then
    echo "FAIL: No output received"
    exit 1
fi

# Check if output contains Claude's response (not just the REPL header)
if echo "$OUTPUT" | grep -q "━━━ Claude ━━━"; then
    echo "PASS: Received response from Claude"
    exit 0
else
    echo "FAIL: No Claude response found in output"
    echo "Output: $OUTPUT"
    exit 1
fi
