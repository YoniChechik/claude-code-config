#!/bin/bash
# test_cc_backspace.sh - Test that backspace cannot erase the prompt character

set -u

# ============================================================
# COLORS
# ============================================================
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

# ============================================================
# TEST COUNTERS
# ============================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================
# TEST UTILITIES
# ============================================================
pass() {
    ((TESTS_PASSED++))
    printf "${GREEN}PASS${RESET}: %s\n" "$1"
}

fail() {
    ((TESTS_FAILED++))
    printf "${RED}FAIL${RESET}: %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "      Expected: %s\n" "$2"
    fi
    if [[ -n "${3:-}" ]]; then
        printf "      Got:      %s\n" "$3"
    fi
}

run_test() {
    ((TESTS_RUN++))
    "$@"
}

# ============================================================
# SETUP
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CC_SCRIPT="$SCRIPT_DIR/cc"

echo "============================================"
echo "CC Backspace Protection Tests"
echo "============================================"
echo ""

# ============================================================
# TESTS
# ============================================================

test_read_uses_prompt_flag() {
    # The read command should use the -p flag to protect the prompt
    if grep -q 'read.*-p' "$CC_SCRIPT"; then
        pass "read command uses -p flag to protect prompt"
    else
        fail "read command uses -p flag to protect prompt" "read with -p flag" "$(grep 'read.*input' "$CC_SCRIPT" || echo 'not found')"
    fi
}

test_prompt_not_separate_printf() {
    # The prompt should NOT be printed separately with printf before read
    # We should find the read with -p, but NOT a separate printf ">" line
    local has_read_with_p=$(grep -c 'read.*-p' "$CC_SCRIPT")
    local has_separate_printf=$(grep -c 'printf "> "$' "$CC_SCRIPT")

    if [[ "$has_read_with_p" -gt 0 ]] && [[ "$has_separate_printf" -eq 0 ]]; then
        pass "prompt is integrated into read command, not separate printf"
    else
        fail "prompt is integrated into read command, not separate printf" "read -p used, no separate printf" "read -p: $has_read_with_p, separate printf: $has_separate_printf"
    fi
}

test_read_has_readline_support() {
    # The read command should have the -e flag for readline support
    if grep -q 'read.*-e' "$CC_SCRIPT"; then
        pass "read command has -e flag for readline support"
    else
        fail "read command has -e flag for readline support"
    fi
}

test_read_command_structure() {
    # Test the exact structure of the read command
    # Should be: read -r -e -p "> " input (or similar order)
    local read_line=$(grep 'read.*input' "$CC_SCRIPT" | grep -v '^#')

    if echo "$read_line" | grep -q '\-r' && \
       echo "$read_line" | grep -q '\-e' && \
       echo "$read_line" | grep -q '\-p'; then
        pass "read command has all required flags (-r, -e, -p)"
    else
        fail "read command has all required flags (-r, -e, -p)" "read -r -e -p" "$read_line"
    fi
}

test_prompt_character_in_read() {
    # Test that the prompt character is specified in the -p flag
    if grep 'read.*-p' "$CC_SCRIPT" | grep -q '>'; then
        pass "prompt character '>' is specified in -p flag"
    else
        local actual=$(grep 'read.*-p' "$CC_SCRIPT" || echo 'not found')
        fail "prompt character '>' is specified in -p flag" "read -p with '>'" "$actual"
    fi
}

# ============================================================
# RUN TESTS
# ============================================================
run_test test_read_uses_prompt_flag
run_test test_prompt_not_separate_printf
run_test test_read_has_readline_support
run_test test_read_command_structure
run_test test_prompt_character_in_read

# ============================================================
# FINAL SUMMARY
# ============================================================
echo ""
echo "============================================"
echo "Test Summary"
echo "============================================"
printf "Total:  %d\n" "$TESTS_RUN"
printf "${GREEN}Passed: %d${RESET}\n" "$TESTS_PASSED"
printf "${RED}Failed: %d${RESET}\n" "$TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    printf "${GREEN}All backspace protection tests passed!${RESET}\n"
    exit 0
else
    printf "${RED}Some tests failed${RESET}\n"
    exit 1
fi
