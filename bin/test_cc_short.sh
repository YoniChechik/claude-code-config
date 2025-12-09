#!/bin/bash

# Test non-interactive short prompt with bin/cc

echo "Testing bin/cc with short prompt..."

OUTPUT=$(echo "hi" | bin/cc 2>&1)

if [ -z "$OUTPUT" ]; then
    echo "FAIL: No output received"
    exit 1
fi

echo "PASS: Received output"
echo "Output: $OUTPUT"
exit 0
