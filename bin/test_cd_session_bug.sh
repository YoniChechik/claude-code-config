#!/bin/bash

# E2E Integration tests for cd session bug
# Bug: After cd command returns with StructuredOutput, session becomes unresponsive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

# Mock claude CLI to simulate the bug scenario
# This simulates what happens in the real flow
setup_mock_claude() {
    local mock_dir="/tmp/test_cd_session_$$"
    mkdir -p "$mock_dir"

    # Create mock claude script
    cat > "$mock_dir/claude" <<'EOF'
#!/bin/bash
# Mock claude CLI that simulates StructuredOutput responses

# If --resume is passed, check if session file exists
SESSION_ID=""
RESUME_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --resume)
            SESSION_ID="$2"
            RESUME_MODE=true
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Create/use session file
if [ -z "$SESSION_ID" ]; then
    SESSION_ID="test-session-$$-$RANDOM"
    SESSION_FILE="/tmp/session-$SESSION_ID"
    echo "0" > "$SESSION_FILE"
else
    SESSION_FILE="/tmp/session-$SESSION_ID"
    if [ ! -f "$SESSION_FILE" ]; then
        # Session file missing - this is the bug!
        echo "BUG: Session file not found for --resume $SESSION_ID" >&2
        exit 1
    fi
fi

# Track turn count
TURN_COUNT=$(cat "$SESSION_FILE")
TURN_COUNT=$((TURN_COUNT + 1))
echo "$TURN_COUNT" > "$SESSION_FILE"

# Output session_id on first turn
if [ "$TURN_COUNT" -eq 1 ]; then
    echo '{"session_id":"'$SESSION_ID'","type":"system","subtype":"init","model":"test-model"}' >&2
fi

# Parse the prompt to determine what to respond with
PROMPT=""
while IFS= read -r line; do
    PROMPT="$line"
done

# Simulate responses based on prompt
if echo "$PROMPT" | grep -q "cd "; then
    # CD command - return StructuredOutput
    TARGET_DIR=$(echo "$PROMPT" | sed 's/.*cd //')
    echo '{"type":"result","stop_reason":"end_turn","structured_output":{"cwd":"'$TARGET_DIR'","response":"Changed to '$TARGET_DIR'"},"usage":{"output_tokens":10},"duration_ms":100}' >&2
elif echo "$PROMPT" | grep -q "ls"; then
    # LS command - return StructuredOutput
    echo '{"type":"result","stop_reason":"end_turn","structured_output":{"cwd":"'$(pwd)'","response":"file1.txt\nfile2.txt\ndir/"},"usage":{"output_tokens":15},"duration_ms":120}' >&2
elif echo "$PROMPT" | grep -q "test prompt"; then
    # Generic test prompt
    echo '{"type":"result","stop_reason":"end_turn","structured_output":{"cwd":"'$(pwd)'","response":"Test response received"},"usage":{"output_tokens":8},"duration_ms":90}' >&2
else
    # Default response
    echo '{"type":"result","stop_reason":"end_turn","structured_output":{"cwd":"'$(pwd)'","response":"Command received: '$PROMPT'"},"usage":{"output_tokens":12},"duration_ms":110}' >&2
fi
EOF
    chmod +x "$mock_dir/claude"

    # Add mock to PATH
    export PATH="$mock_dir:$PATH"
    echo "$mock_dir"
}

cleanup_mock_claude() {
    local mock_dir="$1"
    rm -rf "$mock_dir"
    rm -f /tmp/session-test-session-*
}

# Test 1: Basic session - single command
test_single_command() {
    local mock_dir=$(setup_mock_claude)
    local raw=$(mktemp)

    # Simulate first command
    echo "test prompt" | claude -p "test prompt" --output-format stream-json 2>"$raw" >/dev/null

    # Check if session_id was created
    local session_id
    session_id=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    if [ -n "$session_id" ]; then
        test_pass "Single command: session_id created ($session_id)"
    else
        test_fail "Single command: no session_id found"
    fi

    rm -f "$raw"
    cleanup_mock_claude "$mock_dir"
}

# Test 2: Resume session - second command after first
test_resume_session() {
    local mock_dir=$(setup_mock_claude)
    local raw=$(mktemp)

    # First command
    echo "first" | claude -p "first" --output-format stream-json 2>"$raw" >/dev/null
    local session_id
    session_id=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    # Second command with --resume
    rm -f "$raw"
    echo "second" | claude -p "second" --resume "$session_id" --output-format stream-json 2>"$raw" >/dev/null
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        test_pass "Resume session: second command succeeded"
    else
        test_fail "Resume session: second command failed (exit $exit_code)"
    fi

    rm -f "$raw"
    cleanup_mock_claude "$mock_dir"
}

# Test 3: CD command followed by another command
test_cd_then_command() {
    local mock_dir=$(setup_mock_claude)
    local raw=$(mktemp)

    # First: cd command
    echo "cd /tmp" | claude -p "cd /tmp" --output-format stream-json 2>"$raw" >/dev/null
    local session_id
    session_id=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    # Check StructuredOutput
    local structured_output
    structured_output=$(grep '"type":"result"' "$raw" | tail -1)
    local has_cwd
    has_cwd=$(echo "$structured_output" | jq -r '.structured_output.cwd // empty' 2>/dev/null)

    if [ -z "$has_cwd" ]; then
        test_fail "CD then command: cd response missing cwd"
        rm -f "$raw"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    # Second: ls command
    rm -f "$raw"
    echo "ls" | claude -p "ls" --resume "$session_id" --output-format stream-json 2>"$raw" >/dev/null
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        test_pass "CD then command: ls after cd succeeded"
    else
        test_fail "CD then command: ls after cd failed (exit $exit_code)"
    fi

    rm -f "$raw"
    cleanup_mock_claude "$mock_dir"
}

# Test 4: Multiple CD commands in sequence
test_multiple_cd_commands() {
    local mock_dir=$(setup_mock_claude)
    local raw=$(mktemp)

    # First cd
    echo "cd /tmp" | claude -p "cd /tmp" --output-format stream-json 2>"$raw" >/dev/null
    local session_id
    session_id=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    # Second cd
    rm -f "$raw"
    echo "cd /home" | claude -p "cd /home" --resume "$session_id" --output-format stream-json 2>"$raw" >/dev/null
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        test_fail "Multiple CDs: second cd failed (exit $exit_code)"
        rm -f "$raw"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    # Third cd
    rm -f "$raw"
    echo "cd /usr" | claude -p "cd /usr" --resume "$session_id" --output-format stream-json 2>"$raw" >/dev/null
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        test_pass "Multiple CDs: three cd commands in sequence succeeded"
    else
        test_fail "Multiple CDs: third cd failed (exit $exit_code)"
    fi

    rm -f "$raw"
    cleanup_mock_claude "$mock_dir"
}

# Test 5: Session file persistence
test_session_file_persistence() {
    local mock_dir=$(setup_mock_claude)
    local raw=$(mktemp)

    # First command
    echo "first" | claude -p "first" --output-format stream-json 2>"$raw" >/dev/null
    local session_id
    session_id=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)

    # Check if session file exists
    local session_file="/tmp/session-$session_id"
    if [ ! -f "$session_file" ]; then
        test_fail "Session file persistence: session file not created"
        rm -f "$raw"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    # Delete session file to simulate the bug
    rm -f "$session_file"

    # Try to resume - should fail
    rm -f "$raw"
    echo "second" | claude -p "second" --resume "$session_id" --output-format stream-json 2>"$raw" >/dev/null
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        test_pass "Session file persistence: missing session file causes failure (expected)"
    else
        test_fail "Session file persistence: resumed with missing file (unexpected)"
    fi

    rm -f "$raw"
    cleanup_mock_claude "$mock_dir"
}

# Test 6: ccui.sh run_claude function simulation
test_ccui_run_claude_simulation() {
    local mock_dir=$(setup_mock_claude)

    # Simulate ccui.sh run_claude function
    SESSION_ID=""
    SESSION_CWD=""

    run_claude_mock() {
        local prompt="$1"
        local raw=$(mktemp)
        local args=(-p "$prompt" --output-format stream-json)

        [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")

        # Run mock claude
        echo "$prompt" | claude "${args[@]}" 2>"$raw" >/dev/null
        local exit_code=$?

        # Extract session_id on first call
        if [ -z "$SESSION_ID" ]; then
            SESSION_ID=$(grep '"session_id"' "$raw" | head -1 | jq -r '.session_id // empty' 2>/dev/null)
        fi

        # Extract cwd from structured output
        local result
        result=$(grep '"type":"result"' "$raw" | tail -1)
        if [ -n "$result" ]; then
            SESSION_CWD=$(echo "$result" | jq -r '.structured_output.cwd // empty' 2>/dev/null)
        fi

        rm -f "$raw"
        return $exit_code
    }

    # First command: cd
    run_claude_mock "cd /tmp"
    if [ $? -ne 0 ]; then
        test_fail "ccui simulation: first cd command failed"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    if [ "$SESSION_CWD" != "/tmp" ]; then
        test_fail "ccui simulation: cwd not updated to /tmp (got '$SESSION_CWD')"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    # Second command: ls
    run_claude_mock "ls"
    if [ $? -ne 0 ]; then
        test_fail "ccui simulation: second ls command failed"
        cleanup_mock_claude "$mock_dir"
        return
    fi

    test_pass "ccui simulation: cd followed by ls succeeded"
    cleanup_mock_claude "$mock_dir"
}

# Test 7: JSON parsing in ccui.sh
test_json_parsing() {
    # Test the exact JSON parsing logic from ccui.sh lines 52-53
    local json='{"cwd":"/test/path","response":"test"}'
    local session_cwd
    session_cwd=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)

    if [ "$session_cwd" = "/test/path" ]; then
        test_pass "JSON parsing: cwd extracted correctly"
    else
        test_fail "JSON parsing: cwd extraction failed (got '$session_cwd')"
    fi
}

# Test 8: Real claude CLI availability check
test_real_claude_cli() {
    if command -v claude >/dev/null 2>&1; then
        # Real claude is available - test if it supports --resume
        if claude --help 2>&1 | grep -q -- "--resume"; then
            test_pass "Real claude CLI: available with --resume support"
        else
            test_fail "Real claude CLI: available but no --resume support"
        fi
    else
        test_pass "Real claude CLI: not in PATH (will use mock)"
    fi
}

echo "Running cd session bug tests..."
echo ""

# Basic tests
test_real_claude_cli
test_json_parsing

echo ""
echo "Mock claude tests..."
echo ""

test_single_command
test_resume_session
test_cd_then_command
test_multiple_cd_commands
test_session_file_persistence
test_ccui_run_claude_simulation

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
