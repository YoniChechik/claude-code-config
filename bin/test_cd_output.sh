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
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
