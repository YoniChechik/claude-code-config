#!/bin/bash
# test_gum.sh - Test suite for gum components

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source gum mocks
source "$SCRIPT_DIR/gum_mocks.sh"
gum() { mock_gum "$@"; }
export -f gum

# Source autocomplete
CLAUDE_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/gum_autocomplete.sh"

# Test utilities
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

C_GREEN='\033[32m'
C_RED='\033[31m'
C_RESET='\033[0m'

pass() {
    echo -e "${C_GREEN}✓${C_RESET} $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${C_RED}✗${C_RESET} $1"
    if [[ $# -ge 3 ]]; then
        echo "  Expected: $2"
        echo "  Got:      $3"
    fi
    ((TESTS_FAILED++))
}

run_test() {
    ((TESTS_RUN++))
    "$@"
}

# ============================================
# GUM MOCK TESTS
# ============================================

test_mock_gum_filter_basic() {
    local result
    result=$(echo -e "ask\nfinish\nsync" | gum filter)
    if [[ "$result" == "ask" ]]; then
        pass "mock gum filter returns first line"
    else
        fail "mock gum filter" "ask" "$result"
    fi
}

test_mock_gum_filter_with_value() {
    local result
    result=$(echo -e "ask\nfinish\nsync" | gum filter --value="finish")
    [[ "$result" == "finish" ]] && pass "mock gum filter with --value" || \
        fail "mock gum filter --value" "finish" "$result"
}

test_mock_gum_filter_empty() {
    local result
    result=$(echo "" | gum filter 2>/dev/null)
    local exit_code=$?
    [[ $exit_code -ne 0 ]] && pass "mock gum filter fails on empty input" || \
        fail "mock gum filter empty should fail" "non-zero exit" "exit 0"
}

test_mock_gum_style() {
    local result
    result=$(gum style --foreground="yellow" "test text")
    [[ "$result" == "test text" ]] && pass "mock gum style returns text" || \
        fail "mock gum style" "test text" "$result"
}

test_mock_gum_input() {
    local result
    result=$(gum input --value="test-input")
    [[ "$result" == "test-input" ]] && pass "mock gum input with --value" || \
        fail "mock gum input" "test-input" "$result"
}

# ============================================
# GET_SLASH_COMMANDS TESTS
# ============================================

test_get_slash_commands_returns_list() {
    # Create temp command directory
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/ask.md"
    touch "$TEST_DIR/commands/sync.md"
    touch "$TEST_DIR/commands/finish.md"

    CLAUDE_DIR="$TEST_DIR"
    local result
    result=$(get_slash_commands)

    rm -rf "$TEST_DIR"

    [[ "$result" == *"ask"* ]] && [[ "$result" == *"sync"* ]] && \
        pass "get_slash_commands returns command list" || \
        fail "get_slash_commands should contain ask and sync" "ask, sync" "$result"
}

test_get_slash_commands_empty_dir() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"

    CLAUDE_DIR="$TEST_DIR"
    local result
    result=$(get_slash_commands)

    rm -rf "$TEST_DIR"

    [[ -z "$result" ]] && pass "get_slash_commands empty on no commands" || \
        fail "get_slash_commands empty" "empty" "$result"
}

test_get_slash_commands_sorted() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/zebra.md"
    touch "$TEST_DIR/commands/alpha.md"
    touch "$TEST_DIR/commands/beta.md"

    CLAUDE_DIR="$TEST_DIR"
    local result
    result=$(get_slash_commands)

    rm -rf "$TEST_DIR"

    # Check if first line is alpha
    local first_line
    first_line=$(echo "$result" | head -n 1)

    [[ "$first_line" == "alpha" ]] && pass "get_slash_commands returns sorted list" || \
        fail "get_slash_commands first item" "alpha" "$first_line"
}

# ============================================
# RUN_AUTOCOMPLETE_GUM TESTS
# ============================================

test_autocomplete_gum_returns_selection() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/ask.md"
    touch "$TEST_DIR/commands/sync.md"

    CLAUDE_DIR="$TEST_DIR"

    # Mock will return first line (ask)
    AUTOCOMPLETE_RESULT=""
    run_autocomplete_gum >/dev/null 2>&1

    rm -rf "$TEST_DIR"

    [[ "$AUTOCOMPLETE_RESULT" == "/ask" ]] && \
        pass "autocomplete_gum sets AUTOCOMPLETE_RESULT" || \
        fail "autocomplete_gum result" "/ask" "$AUTOCOMPLETE_RESULT"
}

test_autocomplete_gum_empty_commands() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"

    CLAUDE_DIR="$TEST_DIR"

    AUTOCOMPLETE_RESULT="should-be-cleared"
    run_autocomplete_gum >/dev/null 2>&1
    local exit_code=$?

    rm -rf "$TEST_DIR"

    [[ $exit_code -ne 0 ]] && [[ -z "$AUTOCOMPLETE_RESULT" ]] && \
        pass "autocomplete_gum fails on no commands" || \
        fail "autocomplete_gum empty" "exit 1, empty result" "exit $exit_code, result: $AUTOCOMPLETE_RESULT"
}

test_autocomplete_gum_cancel_clears_result() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/test.md"

    CLAUDE_DIR="$TEST_DIR"

    # Override mock to simulate cancellation
    gum() {
        if [[ "$1" == "filter" ]]; then
            return 1  # Simulate cancel
        fi
        mock_gum "$@"
    }

    AUTOCOMPLETE_RESULT="should-be-cleared"
    run_autocomplete_gum >/dev/null 2>&1

    rm -rf "$TEST_DIR"

    [[ -z "$AUTOCOMPLETE_RESULT" ]] && \
        pass "autocomplete_gum clears result on cancel" || \
        fail "autocomplete_gum cancel" "empty" "$AUTOCOMPLETE_RESULT"

    # Restore normal gum mock
    gum() { mock_gum "$@"; }
}

# ============================================
# INTEGRATION TESTS
# ============================================

test_full_workflow() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/pr-create.md"
    touch "$TEST_DIR/commands/ask.md"

    CLAUDE_DIR="$TEST_DIR"

    # Override mock to return specific value
    gum() {
        if [[ "$1" == "filter" ]]; then
            echo "pr-create"
            return 0
        fi
        mock_gum "$@"
    }

    AUTOCOMPLETE_RESULT=""
    run_autocomplete_gum >/dev/null 2>&1

    rm -rf "$TEST_DIR"

    [[ "$AUTOCOMPLETE_RESULT" == "/pr-create" ]] && \
        pass "full workflow selects command" || \
        fail "full workflow" "/pr-create" "$AUTOCOMPLETE_RESULT"

    # Restore normal gum mock
    gum() { mock_gum "$@"; }
}

# ============================================
# EDGE CASES
# ============================================

test_long_command_name() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/very-long-command-name-that-exceeds-normal-length.md"

    CLAUDE_DIR="$TEST_DIR"

    local result
    result=$(get_slash_commands)

    rm -rf "$TEST_DIR"

    [[ "$result" == "very-long-command-name-that-exceeds-normal-length" ]] && \
        pass "handles long command names" || \
        fail "long command name" "very-long-command-name-that-exceeds-normal-length" "$result"
}

test_special_chars_in_command() {
    local TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/commands"
    touch "$TEST_DIR/commands/pr-123.md"
    touch "$TEST_DIR/commands/fix_bug.md"

    CLAUDE_DIR="$TEST_DIR"

    local result
    result=$(get_slash_commands)

    rm -rf "$TEST_DIR"

    [[ "$result" == *"pr-123"* ]] && [[ "$result" == *"fix_bug"* ]] && \
        pass "handles special characters in command names" || \
        fail "special chars" "pr-123, fix_bug" "$result"
}

# ============================================
# RUN ALL TESTS
# ============================================

echo "Running gum component tests..."
echo ""

# Gum mock tests
run_test test_mock_gum_filter_basic
run_test test_mock_gum_filter_with_value
run_test test_mock_gum_filter_empty
run_test test_mock_gum_style
run_test test_mock_gum_input

echo ""

# get_slash_commands tests
run_test test_get_slash_commands_returns_list
run_test test_get_slash_commands_empty_dir
run_test test_get_slash_commands_sorted

echo ""

# run_autocomplete_gum tests
run_test test_autocomplete_gum_returns_selection
run_test test_autocomplete_gum_empty_commands
run_test test_autocomplete_gum_cancel_clears_result

echo ""

# Integration tests
run_test test_full_workflow

echo ""

# Edge cases
run_test test_long_command_name
run_test test_special_chars_in_command

# ============================================
# SUMMARY
# ============================================

echo ""
echo "============================================"
echo "Test Summary"
echo "============================================"
echo "Total:  $TESTS_RUN"
echo -e "Passed: ${C_GREEN}$TESTS_PASSED${C_RESET}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "Failed: ${C_RED}$TESTS_FAILED${C_RESET}"
else
    echo "Failed: 0"
fi
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed."
    exit 1
fi
