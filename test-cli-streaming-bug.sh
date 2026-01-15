#!/bin/bash
# Simple script to demonstrate CLI streaming bug in resumed sessions

set -e

echo "=== Testing Claude CLI Streaming Bug ==="
echo ""

# First prompt - should stream with text_delta events
echo "1. First prompt (fresh session)..."
OUTPUT1=$(claude -p "Write a 3 paragraph story about a cat" \
  --output-format stream-json \
  --verbose \
  --include-partial-messages 2>&1)

# Extract session ID
SESSION_ID=$(echo "$OUTPUT1" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "   Session ID: $SESSION_ID"

# Count text_delta events
DELTA_COUNT_1=$(echo "$OUTPUT1" | grep -c '"type":"text_delta"' || true)
echo "   text_delta events: $DELTA_COUNT_1"

if [ "$DELTA_COUNT_1" -gt 0 ]; then
    echo "   ✓ First prompt STREAMED"
else
    echo "   ✗ First prompt DID NOT stream"
fi

echo ""

# Second prompt - should stream but doesn't (BUG!)
echo "2. Second prompt (resumed session with --include-partial-messages)..."
OUTPUT2=$(claude -p "Write another 3 paragraph story" \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  --resume "$SESSION_ID" 2>&1)

# Count text_delta events
DELTA_COUNT_2=$(echo "$OUTPUT2" | grep -c '"type":"text_delta"' || true)
echo "   text_delta events: $DELTA_COUNT_2"

if [ "$DELTA_COUNT_2" -gt 0 ]; then
    echo "   ✓ Second prompt STREAMED"
else
    echo "   ✗ Second prompt DID NOT stream (BUG!)"
fi

echo ""
echo "=== Summary ==="
echo "First prompt:  $DELTA_COUNT_1 text_delta events"
echo "Second prompt: $DELTA_COUNT_2 text_delta events"
echo ""

if [ "$DELTA_COUNT_1" -gt 0 ] && [ "$DELTA_COUNT_2" -eq 0 ]; then
    echo "✗ BUG CONFIRMED: Resumed sessions do not stream text_delta events"
    exit 1
elif [ "$DELTA_COUNT_1" -gt 0 ] && [ "$DELTA_COUNT_2" -gt 0 ]; then
    echo "✓ Bug appears to be fixed! Both prompts streamed."
    exit 0
else
    echo "? Unexpected result - check output above"
    exit 2
fi
