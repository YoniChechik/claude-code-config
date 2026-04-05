#!/usr/bin/env bash
set -euo pipefail

echo "=== Webhook Channel E2E Test ==="
echo "Testing: POST to http://127.0.0.1:8788 is received by the channel"
echo ""

# Check that port 8788 is listening
echo "1. Checking port 8788..."
if ! lsof -i :8788 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: Port 8788 is not listening."
  echo "       Start claude with \`cc\` first so the webhook channel is running."
  exit 1
fi
echo "   Port 8788 is up."

# Send test notification
echo "2. Sending test CI failure notification..."
HTTP_CODE=$(curl -s -o /tmp/webhook_test_body.txt -w '%{http_code}' --max-time 5 -X POST http://127.0.0.1:8788 \
  -d "TEST: CI failed on branch main - build #123 failed: 2 tests failed")
RESPONSE=$(cat /tmp/webhook_test_body.txt)

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
