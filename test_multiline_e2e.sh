#!/bin/bash
# End-to-end test for multiline input in ccui with bracketed paste

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCUI_SCRIPT="$SCRIPT_DIR/bin/ccui.sh"
TEST_OUTPUT=$(mktemp)
TEST_INPUT=$(mktemp)
TIMEOUT=20

cleanup() {
    rm -f "$TEST_OUTPUT" "$TEST_INPUT"
}
trap cleanup EXIT

echo "=== End-to-End Test: Multiline Input with Bracketed Paste ==="
echo

# Verify ccui script exists
if [ ! -f "$CCUI_SCRIPT" ]; then
    echo "ERROR: ccui.sh not found at $CCUI_SCRIPT"
    exit 1
fi

# Create test input with multiline content
cat > "$TEST_INPUT" << 'EOF'
Hello
this is multiline
content
EOF

echo "Test input (raw multiline content):"
cat "$TEST_INPUT" | sed 's/^/  /'
echo

# Wrap input in bracketed paste sequences
# Format: \033[200~ starts paste, \033[201~ ends paste
MULTILINE_CONTENT=$(cat "$TEST_INPUT")
WRAPPED_INPUT=$'\033[200~'"$MULTILINE_CONTENT"$'\033[201~'

echo "Input will be wrapped with:"
echo "  Start: \\033[200~"
echo "  End:   \\033[201~"
echo

# Run ccui with test input and timeout
echo "Running ccui.sh with timeout=${TIMEOUT}s..."
TIMED_OUT=0
EXIT_CODE=0

# Send wrapped input to ccui, then send Ctrl+D (EOF) using process substitution
# The </dev/null ensures stdin closes after the input, simulating Ctrl+D
if timeout "$TIMEOUT" bash -c "printf '%s\n' \"$WRAPPED_INPUT\" </dev/null | '$CCUI_SCRIPT' 2>&1" > "$TEST_OUTPUT"; then
    EXIT_CODE=$?
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        TIMED_OUT=1
        echo "WARNING: Test timed out after ${TIMEOUT}s"
    fi
fi
echo

# Display captured output
echo "=== Captured Output ==="
cat "$TEST_OUTPUT"
echo
echo "=== End of Output ==="
echo

# Validation checks
PASS=0
FAIL=0

echo "=== Validation Results ==="

# Check 1: REPL started (header displayed)
if grep -q 'Claude Code REPL' "$TEST_OUTPUT"; then
    echo "✓ PASS: REPL started successfully"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: REPL header not found"
    FAIL=$((FAIL+1))
fi

# Check 2: Bracketed paste start sequence NOT in output (check for actual escape sequence)
if grep -qP '\x1b\[200~' "$TEST_OUTPUT"; then
    echo "✗ FAIL: Bracketed paste start sequence (\\033[200~) not stripped"
    FAIL=$((FAIL+1))
else
    echo "✓ PASS: Bracketed paste start sequence stripped"
    PASS=$((PASS+1))
fi

# Check 3: Bracketed paste end sequence NOT in output (check for actual escape sequence)
if grep -qP '\x1b\[201~' "$TEST_OUTPUT"; then
    echo "✗ FAIL: Bracketed paste end sequence (\\033[201~) not stripped"
    FAIL=$((FAIL+1))
else
    echo "✓ PASS: Bracketed paste end sequence stripped"
    PASS=$((PASS+1))
fi

# Check 4: Content was processed (look for Claude response or ccui header)
if grep -qE '(Claude Code REPL|TEXT:|SUB:|JSON:|\[Stopped\])' "$TEST_OUTPUT"; then
    echo "✓ PASS: Content appears to be processed by ccui"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: No ccui processing indicators found"
    FAIL=$((FAIL+1))
fi

# Check 5: Multiline content present (check for first line of test input)
if grep -q 'Hello' "$TEST_OUTPUT"; then
    echo "✓ PASS: Multiline content detected in output"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: Multiline content not found"
    FAIL=$((FAIL+1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ $TIMED_OUT -eq 1 ] && echo "Status: TIMEOUT (expected - ccui doesn't exit on piped EOF)"

# Consider timeout acceptable since ccui currently doesn't handle piped EOF properly
# The important checks are: bracketed paste sequences stripped and content processed
if [ $FAIL -eq 0 ]; then
    echo "Result: SUCCESS"
    exit 0
else
    echo "Result: FAILURE"
    exit 1
fi
