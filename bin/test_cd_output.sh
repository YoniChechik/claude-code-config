#!/bin/bash

# Test cc_filter.jq handling of StructuredOutput response field
# This tests that cd command responses are properly displayed to users

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

# Test: StructuredOutput with non-empty response shows the response
test_structured_output_with_response() {
    local json='{"type":"result","structured_output":{"cwd":"/home/ubuntu","response":"Changed to /home/ubuntu"}}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Should contain LINE:Changed to /home/ubuntu
    if echo "$output" | grep -q "LINE:Changed to /home/ubuntu"; then
        test_pass "StructuredOutput with response displays response"
    else
        test_fail "StructuredOutput with response: got '$output'"
    fi
}

# Test: StructuredOutput with empty response shows nothing (the bug)
test_structured_output_empty_response() {
    local json='{"type":"result","structured_output":{"cwd":"/home/ubuntu","response":""}}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Should only contain JSON: with cwd
    if echo "$output" | grep -q "JSON:" && ! echo "$output" | grep -q "LINE:"; then
        test_pass "StructuredOutput with empty response shows only JSON cwd"
    else
        test_fail "StructuredOutput with empty response: got '$output'"
    fi
}

# Test: StructuredOutput with multiline response
test_structured_output_multiline() {
    local json='{"type":"result","structured_output":{"cwd":"/home/ubuntu","response":"Line 1\nLine 2\nLine 3"}}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Should contain LINE: for each line
    local line_count
    line_count=$(echo "$output" | grep -c "^LINE:")

    if [[ $line_count -eq 3 ]]; then
        test_pass "StructuredOutput multiline response (3 lines)"
    else
        test_fail "StructuredOutput multiline: expected 3 LINE: entries, got $line_count"
    fi
}

# Test: StructuredOutput cwd is included in JSON
test_structured_output_cwd_json() {
    local json='{"type":"result","structured_output":{"cwd":"/path/to/dir","response":"test"}}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Should contain JSON: with cwd
    if echo "$output" | grep -q 'JSON:{"cwd":"/path/to/dir"}'; then
        test_pass "StructuredOutput includes cwd in JSON"
    else
        test_fail "StructuredOutput cwd JSON: got '$output'"
    fi
}

# Test: Result without structured_output is handled
test_result_without_structured_output() {
    local json='{"type":"result","stop_reason":"end_turn"}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Should produce no output (empty)
    if [[ -z "$output" ]]; then
        test_pass "Result without structured_output produces no output"
    else
        test_fail "Result without structured_output: got '$output'"
    fi
}

# Test: ccui.sh processes JSON output correctly
test_ccui_json_parsing() {
    # Simulate the JSON parsing in ccui.sh
    local json='{"cwd":"/test/path"}'
    local cwd
    cwd=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)

    if [[ "$cwd" == "/test/path" ]]; then
        test_pass "ccui.sh JSON cwd parsing works"
    else
        test_fail "ccui.sh JSON cwd parsing: got '$cwd'"
    fi
}

# Test: cd response from prompt instructions
test_cd_response_format() {
    # The prompt says: "For cd commands: Include the new directory path and confirmation"
    # Example: "Changed to /path/to/dir"
    local json='{"type":"result","structured_output":{"cwd":"/home/ubuntu/project","response":"Changed to /home/ubuntu/project"}}'
    local output
    output=$(echo "$json" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    if echo "$output" | grep -q "LINE:Changed to /home/ubuntu/project"; then
        test_pass "cd command response format correct"
    else
        test_fail "cd command response format: got '$output'"
    fi
}

# E2E Test: Simulate cd command followed by another command
# Verifies both outputs are visible through the cc_filter.jq pipeline
test_e2e_cd_then_command() {
    # Simulate a session with:
    # 1. User runs "cd /home/ubuntu/project"
    # 2. Claude responds with StructuredOutput containing "Changed to /home/ubuntu/project"
    # 3. User runs "ls"
    # 4. Claude responds with file listing

    # First command: cd
    local cd_result='{"type":"result","structured_output":{"cwd":"/home/ubuntu/project","response":"Changed to /home/ubuntu/project"}}'
    local cd_output
    cd_output=$(echo "$cd_result" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Verify cd output is visible
    if ! echo "$cd_output" | grep -q "LINE:Changed to /home/ubuntu/project"; then
        test_fail "E2E cd then command: cd response not visible"
        return
    fi

    # Second command: ls (simulated output)
    local ls_result='{"type":"result","structured_output":{"cwd":"/home/ubuntu/project","response":"Listed directory contents:\nfile1.txt\nfile2.txt\nsubdir/"}}'
    local ls_output
    ls_output=$(echo "$ls_result" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Verify ls output is visible
    if ! echo "$ls_output" | grep -q "LINE:Listed directory contents"; then
        test_fail "E2E cd then command: ls response not visible"
        return
    fi

    # Verify both cwd values are tracked in JSON output
    if ! echo "$cd_output" | grep -q 'JSON:{"cwd":"/home/ubuntu/project"}'; then
        test_fail "E2E cd then command: cd cwd not in JSON"
        return
    fi

    if ! echo "$ls_output" | grep -q 'JSON:{"cwd":"/home/ubuntu/project"}'; then
        test_fail "E2E cd then command: ls cwd not preserved in JSON"
        return
    fi

    test_pass "E2E cd then command: both outputs visible"
}

# E2E Test: Empty response is clearly identifiable as a bug
test_e2e_empty_response_bug_detection() {
    # This tests that an empty response shows no LINE: output
    # which allows us to detect the bug when Claude sends empty response
    local empty_result='{"type":"result","structured_output":{"cwd":"/home/ubuntu","response":""}}'
    local output
    output=$(echo "$empty_result" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Empty response should produce only JSON cwd output, no LINE:
    # This is the "bug state" - we can detect it
    local has_line_prefix
    has_line_prefix=$(echo "$output" | grep "^LINE:" || true)

    if [[ -z "$has_line_prefix" ]] && echo "$output" | grep -q "^JSON:"; then
        test_pass "E2E empty response bug detectable (no visible text)"
    else
        test_fail "E2E empty response: unexpected output '$output'"
    fi
}

# E2E Test: Full ccui.sh pipeline simulation
test_e2e_ccui_pipeline() {
    # Simulate what ccui.sh does: parse JSON output and display
    # This tests the TEXT:, LINE:, JSON: prefix handling

    local cd_result='{"type":"result","structured_output":{"cwd":"/tmp/test","response":"Changed to /tmp/test"}}'

    # Run through cc_filter.jq
    local filter_output
    filter_output=$(echo "$cd_result" | jq -r -f "$CLAUDE_DIR/bin/cc_filter.jq" 2>/dev/null)

    # Simulate ccui.sh processing
    local visible_output=""
    local session_cwd=""

    while IFS= read -r line; do
        case "$line" in
            TEXT:*) visible_output+="${line#TEXT:}" ;;
            LINE:*) visible_output+="${line#LINE:}"$'\n' ;;
            JSON:*)
                json="${line#JSON:}"
                session_cwd=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)
                ;;
        esac
    done <<< "$filter_output"

    # Verify visible output contains the cd message
    if ! echo "$visible_output" | grep -q "Changed to /tmp/test"; then
        test_fail "E2E ccui pipeline: visible output missing cd message"
        return
    fi

    # Verify cwd was parsed
    if [[ "$session_cwd" != "/tmp/test" ]]; then
        test_fail "E2E ccui pipeline: cwd not parsed correctly (got '$session_cwd')"
        return
    fi

    test_pass "E2E ccui pipeline: cd message visible and cwd tracked"
}

echo "Running cd output visibility tests..."
echo ""

test_structured_output_with_response
test_structured_output_empty_response
test_structured_output_multiline
test_structured_output_cwd_json
test_result_without_structured_output
test_ccui_json_parsing
test_cd_response_format

echo ""
echo "Running E2E tests..."
echo ""

test_e2e_cd_then_command
test_e2e_empty_response_bug_detection
test_e2e_ccui_pipeline

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
