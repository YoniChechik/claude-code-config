#!/usr/bin/env bash
set -euo pipefail

echo "=== Webhook Channel E2E Test ==="
echo "Testing: POST to webhook channel is received"
echo ""

# Find a listening webhook port in the range 8788-8797
echo "1. Scanning ports 8788-8797 for active webhook..."
PORT=""
for p in $(seq 8788 8797); do
  if curl -s --max-time 1 "http://127.0.0.1:$p/health" 2>/dev/null | grep -q 'ok'; then
    PORT=$p
    break
  fi
done

if [ -z "$PORT" ]; then
  echo "ERROR: No webhook channel found on ports 8788-8797."
  echo "       Start claude with \`cc\` first so the webhook channel is running."
  exit 1
fi
echo "   Found webhook on port $PORT."

# Send test notification
TMPFILE=$(mktemp)
echo "2. Sending test CI failure notification..."
HTTP_CODE=$(curl -s -o "$TMPFILE" -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:$PORT" \
  --data-raw "TEST: CI failed on branch main - build #123 failed: 2 tests failed")
RESPONSE=$(cat "$TMPFILE")
rm -f "$TMPFILE"

echo "   HTTP status: $HTTP_CODE"
echo "   Response: $RESPONSE"

if [ "$HTTP_CODE" = "200" ] && [ "$RESPONSE" = "ok" ]; then
  echo ""
  echo "PASS: Webhook accepted the message."
  echo "Note: Full autonomous response verification requires a live Claude session."
else
  echo ""
  echo "FAIL: Expected HTTP 200 with body 'ok', got HTTP $HTTP_CODE with body '$RESPONSE'"
  exit 1
fi
