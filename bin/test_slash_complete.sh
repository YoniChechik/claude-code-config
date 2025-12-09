#!/bin/bash

# test_slash_complete.sh - Tests for slash command completion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slash_complete.sh"

# Test utilities
TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    if [ "$expected" = "$actual" ]; then
        echo "✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ $test_name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local test_name="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ $test_name"
        echo "  Expected to contain: '$needle'"
        echo "  Actual:   '$haystack'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_true() {
    local condition="$1"
    local test_name="$2"

    if [ "$condition" = "0" ]; then
        echo "✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_false() {
    local condition="$1"
    local test_name="$2"

    if [ "$condition" != "0" ]; then
        echo "✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================
# TESTS
# ============================================================

echo "Testing slash command completion..."
echo ""

# Test 1: Command discovery
echo "Test: Command Discovery"
commands=$(get_commands)
assert_contains "ask" "$commands" "Should find 'ask' command"
assert_contains "sync" "$commands" "Should find 'sync' command"
assert_contains "new-feature" "$commands" "Should find 'new-feature' command"
echo ""

# Test 2: Fuzzy matching
echo "Test: Fuzzy Matching"
fuzzy_match "ask" "ask" && result1=0 || result1=1
assert_true "$result1" "Exact match should work"

fuzzy_match "as" "ask" && result2=0 || result2=1
assert_true "$result2" "Prefix match should work"

fuzzy_match "yn" "sync" && result3=0 || result3=1
assert_true "$result3" "Substring match should work"

fuzzy_match "xyz" "ask" && result4=0 || result4=1
assert_false "$result4" "Non-matching pattern should fail"

fuzzy_match "" "ask" && result5=0 || result5=1
assert_true "$result5" "Empty pattern should match everything"
echo ""

# Test 3: Fuzzy scoring
echo "Test: Fuzzy Scoring"
score_exact=$(fuzzy_score "ask" "ask")
score_prefix=$(fuzzy_score "as" "ask")
score_substring=$(fuzzy_score "yn" "sync")

assert_equals "0" "$score_exact" "Exact match should have score 0"
assert_equals "1" "$score_prefix" "Prefix match should have score 1"

# Substring should have higher score than prefix
if [ "$score_substring" -gt "$score_prefix" ]; then
    echo "✓ Substring match should have higher score than prefix"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "✗ Substring match should have higher score than prefix"
    echo "  Prefix score: $score_prefix"
    echo "  Substring score: $score_substring"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo ""

# Test 4: Match ordering
echo "Test: Match Ordering"
matches=$(get_matches "")
num_matches=$(echo "$matches" | wc -l)
if [ "$num_matches" -gt 0 ]; then
    echo "✓ Empty pattern returns all commands ($num_matches commands)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "✗ Empty pattern should return commands"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

matches=$(get_matches "new")
assert_contains "new-feature" "$matches" "Should match 'new-feature'"

matches=$(get_matches "pr")
first_match=$(echo "$matches" | head -1)
# pr- commands should be at top
if [[ "$first_match" == pr-* ]]; then
    echo "✓ Best matches appear first (got: $first_match)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "✗ Best matches should appear first"
    echo "  First match: $first_match"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo ""

# Test 5: Case insensitivity
echo "Test: Case Insensitivity"
fuzzy_match "ASK" "ask" && result6=0 || result6=1
assert_true "$result6" "Case insensitive match should work (upper -> lower)"

fuzzy_match "ask" "ASK" && result7=0 || result7=1
assert_true "$result7" "Case insensitive match should work (lower -> upper)"
echo ""

# Test 6: Edge cases
echo "Test: Edge Cases"
matches=$(get_matches "nonexistent")
if [ -z "$matches" ]; then
    echo "✓ Non-matching pattern returns empty"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "✗ Non-matching pattern should return empty"
    echo "  Got: $matches"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test with special characters (should not crash)
matches=$(get_matches "a*b")
echo "✓ Special characters don't crash"
TESTS_PASSED=$((TESTS_PASSED + 1))
echo ""

# ============================================================
# SUMMARY
# ============================================================

echo "========================================"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "========================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed."
    exit 1
fi
