# Bug Report: CLI Not Sending text_delta Events for Resumed Sessions

## Summary
The Claude CLI (v2.1.6) does not send `text_delta` events for resumed sessions, even when the `--include-partial-messages` flag is provided. This prevents real-time streaming of text in the second and subsequent prompts in ccweb.

## Root Cause
The bug is in the **CLI orchestrator**, not the web application. The CLI correctly sends `text_delta` events for fresh sessions but fails to do so for resumed sessions.

## Evidence

### Test Script
```bash
#!/bin/bash
cd /tmp

# First prompt (fresh session)
OUTPUT1=$(claude -p "First: What is 1+1?" \
  --output-format stream-json \
  --verbose \
  --json-schema '{"type":"object","properties":{"response":{"type":"string"}},"required":["response"]}' \
  --include-partial-messages 2>&1)

SESSION_ID=$(echo "$OUTPUT1" | grep -m1 '"session_id"' | sed 's/.*"session_id":"\([^"]*\)".*/\1/')

# Count text_delta events in first prompt
TEXT_DELTA_COUNT=$(echo "$OUTPUT1" | grep -c "text_delta" || true)
echo "First prompt text_delta events: $TEXT_DELTA_COUNT"  # Result: 1

# Second prompt (resumed session)
OUTPUT2=$(claude -p "Second: What is 2+2?" \
  --output-format stream-json \
  --verbose \
  --json-schema '{"type":"object","properties":{"response":{"type":"string"}},"required":["response"]}' \
  --include-partial-messages \
  --resume "$SESSION_ID" 2>&1)

# Count text_delta events in second prompt
TEXT_DELTA_COUNT2=$(echo "$OUTPUT2" | grep -c "text_delta" || true)
echo "Second prompt text_delta events: $TEXT_DELTA_COUNT2"  # Result: 0 (BUG!)
```

### Results
- **Fresh session**: `text_delta` events ARE sent ✓
- **Resumed session**: `text_delta` events are NOT sent ✗

### CLI Version
```
claude --version
# Output: 2.1.6
```

## Web App Behavior

### Current Implementation
The web app (ccweb) has implemented a **fallback mechanism** that handles this CLI bug gracefully:

1. Web app correctly passes `--include-partial-messages` flag to CLI
2. Web app tracks whether `text_delta` events were received (`hasReceivedTextDelta`)
3. If NO `text_delta` events arrive, web app falls back to showing the `StructuredOutput` text
4. This ensures text is ALWAYS displayed, even when CLI fails to stream

### Code Location
See `web-app/lib/claude-client.ts` lines 215-228 for fallback implementation.

### Test Coverage
See `web-app/__tests__/consecutive-prompts.test.ts` which validates both:
- Text appears when `text_delta` events ARE received (streaming works)
- Text appears when `text_delta` events are NOT received (fallback works)

## Impact

### User Experience
- **First prompt**: Text streams in real-time ✓
- **Second+ prompts**: Text appears all at once (no streaming) ✗

### Workaround
The web app's fallback mechanism ensures text is always displayed, but users don't get the improved UX of real-time streaming for resumed sessions.

## Next Steps

1. **File bug with Claude Code team**: This is a CLI orchestrator bug that needs to be fixed upstream
2. **Current workaround**: The web app's fallback mechanism provides acceptable UX until CLI is fixed
3. **No web app changes needed**: The web app is already handling this correctly

## Technical Details

### What Web App Sends
```typescript
// Correct CLI args for resumed session (from debug logs)
[
  '-p', 'What is 2+2?',
  '--output-format', 'stream-json',
  '--verbose',
  '--json-schema', '{"type":"object","properties":{...}}',
  '--resume', '880406bf-66a3-4bb0-992d-2429c6f1ee69',
  '--include-partial-messages'  // ← Flag IS being passed
]
```

### What CLI Should Send (But Doesn't)
```json
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"..."}}}
```

## Conclusion

The web app is **correctly implemented** and has proper fallback behavior. The bug is in the **Claude CLI orchestrator** which needs to be fixed to respect the `--include-partial-messages` flag for resumed sessions.
