# CRITICAL BUG: Session Resume Completely Broken

## Summary
The `--resume` flag in the Claude CLI is completely broken. When attempting to resume a session, it creates a NEW session instead of resuming the existing one. This makes ccui.sh completely unresponsive after the first command.

## Root Cause
The `--resume <session_id>` flag does not actually resume the specified session. Instead, it creates a brand new session with a different session_id.

## Reproduction Steps

### Test 1: Basic Session Resume Failure

```bash
# Create a new session
claude -p "echo hello" --output-format stream-json --verbose \
  --json-schema '{"type":"object","properties":{"cwd":{"type":"string"},"response":{"type":"string"}},"required":["cwd","response"]}' \
  2>&1 | grep '"session_id"'

# Output shows: "session_id":"86a2ba23-b2f8-46bf-803c-5f2d220e9e94"
```

```bash
# Try to resume the session
claude -p "echo world" --resume "86a2ba23-b2f8-46bf-803c-5f2d220e9e94" \
  --output-format stream-json --verbose \
  --json-schema '{"type":"object","properties":{"cwd":{"type":"string"},"response":{"type":"string"}},"required":["cwd","response"]}' \
  2>&1 | grep '"session_id"'

# Output shows: "session_id":"ccd3acb6-c956-4403-ac77-d5c42a148e27"
# ^^^ DIFFERENT SESSION ID! Should be the same!
```

### Test 2: Session Directory Empty

```bash
# Check if session was persisted
ls -la ~/.claude/session-env/86a2ba23-b2f8-46bf-803c-5f2d220e9e94/

# Output:
total 60
drwxrwxr-x   2 ubuntu ubuntu  4096 Jan 13 08:51 .
drwxrwxr-x 725 ubuntu ubuntu 53248 Jan 13 08:51 ..

# The directory exists but is EMPTY!
# No session data was persisted!
```

## Impact on ccui.sh

This bug makes ccui.sh completely unusable after the first command:

1. User runs first command (e.g., "cd /tmp")
2. ccui.sh extracts session_id from response
3. User runs second command (e.g., "ls")
4. ccui.sh tries to --resume the session
5. Claude creates NEW session instead of resuming old one
6. New session has no context from previous command
7. User sees "nothing happens" or unexpected behavior

## Expected Behavior

When `--resume <session_id>` is used:
1. Claude should load the existing session from ~/.claude/session-env/<session_id>/
2. The response should include the SAME session_id
3. The conversation history should be preserved
4. The session should continue from where it left off

## Actual Behavior

When `--resume <session_id>` is used:
1. Claude creates a BRAND NEW session with a different ID
2. The old session is ignored
3. No conversation history is preserved
4. The session starts from scratch

## Files Affected

- `/home/ubuntu/.claude/bin/ccui.sh` - Relies on --resume working properly
- Session persistence mechanism in Claude CLI core

## Fix Required

This bug is in the Claude CLI itself, not in ccui.sh. The fix requires:

1. Investigating why --resume doesn't load existing sessions
2. Fixing session persistence (sessions are not being saved)
3. Fixing session loading (--resume creates new session instead)
4. Testing that session state is properly maintained across turns

## Workarounds

There is NO workaround for this bug. The ccui.sh REPL cannot function without working session resumption.

## Test Files Created

- `/home/ubuntu/.claude/bin/test_cd_real_integration.sh` - Integration test that reproduces the bug
- `/home/ubuntu/.claude/bin/test_cd_session_bug.sh` - Mock tests for session behavior

## Date Discovered

2026-01-13

## Priority

**CRITICAL** - This bug makes the entire ccui.sh REPL non-functional after the first command.
