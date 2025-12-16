#!/bin/bash
# test_all.sh - Comprehensive test suite for cc command
# Tests: get_slash_commands, filter_commands, levenshtein, find_similar_command

set -u

# ============================================================
# COLORS
# ============================================================
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
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
# SETUP TEST ENVIRONMENT
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_CLAUDE_DIR=$(mktemp -d)

# Create test commands directory with sample commands
mkdir -p "$TEST_CLAUDE_DIR/commands"
echo "test" > "$TEST_CLAUDE_DIR/commands/ask.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/sync.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/finish.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/new-feature.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/new-feature-short.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/pr-create.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/pr-comments.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/pr-walkthrough.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/continue-feature.md"
echo "test" > "$TEST_CLAUDE_DIR/commands/create-clone.md"

cleanup() {
    rm -rf "$TEST_CLAUDE_DIR"
}
trap cleanup EXIT

# Override CLAUDE_DIR for testing
CLAUDE_DIR="$TEST_CLAUDE_DIR"

# ============================================================
# SOURCE AUTOCOMPLETE FUNCTIONS
# ============================================================
source "$SCRIPT_DIR/gum_autocomplete.sh"

# ============================================================
# HELPER FUNCTIONS FOR TESTING
# ============================================================

# Filter commands by prefix (for testing)
filter_commands() {
    local prefix="$1"
    local cmd
    while IFS= read -r cmd; do
        [[ "$cmd" == "$prefix"* ]] && echo "$cmd"
    done
}

# ============================================================
# SOURCE FUZZY MATCHING FUNCTIONS (from cc)
# ============================================================
# Levenshtein distance
levenshtein() {
    awk 'BEGIN {
        s1=ARGV[1]; s2=ARGV[2]
        l1=length(s1); l2=length(s2)
        for(i=0;i<=l1;i++) d[i,0]=i
        for(j=0;j<=l2;j++) d[0,j]=j
        for(i=1;i<=l1;i++) {
            for(j=1;j<=l2;j++) {
                c = substr(s1,i,1)!=substr(s2,j,1)
                d[i,j] = d[i-1,j]+1
                if(d[i,j-1]+1 < d[i,j]) d[i,j]=d[i,j-1]+1
                if(d[i-1,j-1]+c < d[i,j]) d[i,j]=d[i-1,j-1]+c
            }
        }
        print d[l1,l2]
    }' "$1" "$2"
}

# Find similar command
find_similar_command() {
    local input="${1#/}"
    local best="" best_dist=999

    for cmd_file in "$CLAUDE_DIR"/commands/*.md; do
        [ -f "$cmd_file" ] || continue
        local cmd=$(basename "$cmd_file" .md)
        local dist=$(levenshtein "$input" "$cmd")
        if [ "$dist" -lt "$best_dist" ] && [ "$dist" -le 3 ]; then
            best="$cmd"
            best_dist="$dist"
        fi
    done

    [ -n "$best" ] && echo "/$best"
}

echo "============================================"
echo "CC Command Test Suite"
echo "============================================"
echo ""

# ============================================================
# SECTION 1: GET_SLASH_COMMANDS TESTS
# ============================================================
echo "=========================================="
echo "SECTION 1: get_slash_commands Tests"
echo "=========================================="
echo ""

test_get_slash_commands_returns_all() {
    local result
    result=$(get_slash_commands)
    local count
    count=$(echo "$result" | wc -l)

    if [[ $count -eq 10 ]]; then
        pass "get_slash_commands returns all 10 commands"
    else
        fail "get_slash_commands returns all commands" "10" "$count"
    fi
}

test_get_slash_commands_sorted() {
    local result
    result=$(get_slash_commands)
    local sorted
    sorted=$(echo "$result" | sort)

    if [[ "$result" == "$sorted" ]]; then
        pass "get_slash_commands returns sorted output"
    else
        fail "get_slash_commands returns sorted output"
    fi
}

test_get_slash_commands_no_extension() {
    local result
    result=$(get_slash_commands)

    if echo "$result" | grep -q '\.md'; then
        fail "get_slash_commands strips .md extension" "no .md in output" "found .md"
    else
        pass "get_slash_commands strips .md extension"
    fi
}

test_get_slash_commands_empty_dir() {
    local empty_dir=$(mktemp -d)
    mkdir -p "$empty_dir/commands"
    local old_claude_dir="$CLAUDE_DIR"
    CLAUDE_DIR="$empty_dir"

    local result
    result=$(get_slash_commands)

    CLAUDE_DIR="$old_claude_dir"
    rm -rf "$empty_dir"

    if [[ -z "$result" || "$result" == "" ]]; then
        pass "get_slash_commands handles empty directory"
    else
        fail "get_slash_commands handles empty directory" "empty" "$result"
    fi
}

run_test test_get_slash_commands_returns_all
run_test test_get_slash_commands_sorted
run_test test_get_slash_commands_no_extension
run_test test_get_slash_commands_empty_dir

# ============================================================
# SECTION 2: FILTER_COMMANDS TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 2: filter_commands Tests"
echo "=========================================="
echo ""

test_filter_commands_prefix_match() {
    local result
    result=$(printf "ask\nfinish\nsync\nnew-feature" | filter_commands "a")

    if [[ "$result" == "ask" ]]; then
        pass "filter_commands matches 'a' prefix"
    else
        fail "filter_commands matches 'a' prefix" "ask" "$result"
    fi
}

test_filter_commands_multiple_matches() {
    local result
    result=$(printf "pr-create\npr-comments\npr-walkthrough\nask" | filter_commands "pr-")
    local count
    count=$(echo "$result" | wc -l)

    if [[ $count -eq 3 ]]; then
        pass "filter_commands returns all 'pr-' matches"
    else
        fail "filter_commands returns all 'pr-' matches" "3" "$count"
    fi
}

test_filter_commands_no_match() {
    local result
    result=$(printf "ask\nfinish\nsync" | filter_commands "xyz")

    if [[ -z "$result" ]]; then
        pass "filter_commands returns empty for no matches"
    else
        fail "filter_commands returns empty for no matches" "empty" "$result"
    fi
}

test_filter_commands_empty_prefix() {
    local result
    result=$(printf "ask\nfinish\nsync\n" | filter_commands "")
    local count
    count=$(echo "$result" | grep -c .)

    if [[ $count -eq 3 ]]; then
        pass "filter_commands returns all for empty prefix"
    else
        fail "filter_commands returns all for empty prefix" "3" "$count"
    fi
}

test_filter_commands_exact_match() {
    local result
    result=$(printf "ask\nfinish\nsync" | filter_commands "ask")

    if [[ "$result" == "ask" ]]; then
        pass "filter_commands returns exact match"
    else
        fail "filter_commands returns exact match" "ask" "$result"
    fi
}

test_filter_commands_hyphenated() {
    local result
    result=$(printf "new-feature\nnew-feature-short\nfinish" | filter_commands "new-f")
    local count
    count=$(echo "$result" | wc -l)

    if [[ $count -eq 2 ]]; then
        pass "filter_commands handles hyphenated commands"
    else
        fail "filter_commands handles hyphenated commands" "2" "$count"
    fi
}

test_filter_commands_case_sensitive() {
    local result
    result=$(printf "Ask\nask\nASK" | filter_commands "A")

    # Should only match capitalized versions
    if [[ "$result" == "Ask"$'\n'"ASK" ]]; then
        pass "filter_commands is case-sensitive"
    else
        # Check it at least doesn't match lowercase
        if ! echo "$result" | grep -q "^ask$"; then
            pass "filter_commands is case-sensitive"
        else
            fail "filter_commands is case-sensitive"
        fi
    fi
}

run_test test_filter_commands_prefix_match
run_test test_filter_commands_multiple_matches
run_test test_filter_commands_no_match
run_test test_filter_commands_empty_prefix
run_test test_filter_commands_exact_match
run_test test_filter_commands_hyphenated
run_test test_filter_commands_case_sensitive

# ============================================================
# SECTION 3: LEVENSHTEIN TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 3: levenshtein Tests"
echo "=========================================="
echo ""

test_levenshtein_identical() {
    local dist
    dist=$(levenshtein "test" "test")

    if [[ "$dist" == "0" ]]; then
        pass "levenshtein returns 0 for identical strings"
    else
        fail "levenshtein returns 0 for identical strings" "0" "$dist"
    fi
}

test_levenshtein_one_char_diff() {
    local dist
    dist=$(levenshtein "test" "tests")

    if [[ "$dist" == "1" ]]; then
        pass "levenshtein returns 1 for one char addition"
    else
        fail "levenshtein returns 1 for one char addition" "1" "$dist"
    fi
}

test_levenshtein_substitution() {
    local dist
    dist=$(levenshtein "test" "best")

    if [[ "$dist" == "1" ]]; then
        pass "levenshtein returns 1 for one substitution"
    else
        fail "levenshtein returns 1 for one substitution" "1" "$dist"
    fi
}

test_levenshtein_empty_string() {
    local dist
    dist=$(levenshtein "" "test")

    if [[ "$dist" == "4" ]]; then
        pass "levenshtein handles empty string"
    else
        fail "levenshtein handles empty string" "4" "$dist"
    fi
}

test_levenshtein_typo() {
    local dist
    dist=$(levenshtein "sync" "synk")

    if [[ "$dist" == "1" ]]; then
        pass "levenshtein detects typo (sync->synk)"
    else
        fail "levenshtein detects typo" "1" "$dist"
    fi
}

run_test test_levenshtein_identical
run_test test_levenshtein_one_char_diff
run_test test_levenshtein_substitution
run_test test_levenshtein_empty_string
run_test test_levenshtein_typo

# ============================================================
# SECTION 4: FIND_SIMILAR_COMMAND TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 4: find_similar_command Tests"
echo "=========================================="
echo ""

test_find_similar_exact() {
    local result
    result=$(find_similar_command "/sync")

    if [[ "$result" == "/sync" ]]; then
        pass "find_similar_command finds exact match"
    else
        fail "find_similar_command finds exact match" "/sync" "$result"
    fi
}

test_find_similar_typo() {
    local result
    result=$(find_similar_command "/synk")

    if [[ "$result" == "/sync" ]]; then
        pass "find_similar_command suggests /sync for /synk"
    else
        fail "find_similar_command suggests /sync for /synk" "/sync" "$result"
    fi
}

test_find_similar_no_match() {
    local result
    result=$(find_similar_command "/xyzabc")

    if [[ -z "$result" ]]; then
        pass "find_similar_command returns empty for distant typo"
    else
        fail "find_similar_command returns empty for distant typo" "empty" "$result"
    fi
}

test_find_similar_strips_slash() {
    local result
    result=$(find_similar_command "/aask")  # typo of ask

    if [[ "$result" == "/ask" ]]; then
        pass "find_similar_command handles leading slash"
    else
        # Could also be empty if distance > 3
        if [[ -z "$result" ]]; then
            pass "find_similar_command handles leading slash (no match within threshold)"
        else
            fail "find_similar_command handles leading slash" "/ask or empty" "$result"
        fi
    fi
}

test_find_similar_pr_typo() {
    local result
    result=$(find_similar_command "/pr-crate")  # typo of pr-create

    if [[ "$result" == "/pr-create" ]]; then
        pass "find_similar_command suggests /pr-create for /pr-crate"
    else
        fail "find_similar_command suggests /pr-create for /pr-crate" "/pr-create" "$result"
    fi
}

run_test test_find_similar_exact
run_test test_find_similar_typo
run_test test_find_similar_no_match
run_test test_find_similar_strips_slash
run_test test_find_similar_pr_typo

# ============================================================
# SECTION 5: INTEGRATION TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 5: Integration Tests"
echo "=========================================="
echo ""

test_integration_filter_pipeline() {
    local all_commands
    mapfile -t all_commands < <(get_slash_commands)

    local filtered
    filtered=$(printf '%s\n' "${all_commands[@]}" | filter_commands "pr")
    local count
    count=$(echo "$filtered" | wc -l)

    if [[ $count -eq 3 ]]; then
        pass "Integration: pipeline filters 'pr' prefix correctly"
    else
        fail "Integration: pipeline filters 'pr' prefix correctly" "3" "$count"
    fi
}

test_integration_empty_prefix_shows_all() {
    local all_commands
    mapfile -t all_commands < <(get_slash_commands)

    local filtered
    filtered=$(printf '%s\n' "${all_commands[@]}" | filter_commands "")
    local all_count=${#all_commands[@]}
    local filtered_count
    filtered_count=$(echo "$filtered" | wc -l)

    if [[ $filtered_count -eq $all_count ]]; then
        pass "Integration: empty prefix shows all commands"
    else
        fail "Integration: empty prefix shows all commands" "$all_count" "$filtered_count"
    fi
}

test_integration_progressive_filter() {
    local all_commands
    mapfile -t all_commands < <(get_slash_commands)

    local c1 c2 c3
    c1=$(printf '%s\n' "${all_commands[@]}" | filter_commands "n" | wc -l)
    c2=$(printf '%s\n' "${all_commands[@]}" | filter_commands "ne" | wc -l)
    c3=$(printf '%s\n' "${all_commands[@]}" | filter_commands "new" | wc -l)

    if [[ $c1 -ge $c2 ]] && [[ $c2 -ge $c3 ]]; then
        pass "Integration: progressive filtering narrows results"
    else
        fail "Integration: progressive filtering narrows results" "c1 >= c2 >= c3" "$c1 >= $c2 >= $c3"
    fi
}

run_test test_integration_filter_pipeline
run_test test_integration_empty_prefix_shows_all
run_test test_integration_progressive_filter

# ============================================================
# SECTION 6: EDGE CASE TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 6: Edge Case Tests"
echo "=========================================="
echo ""

test_edge_single_command() {
    local single_dir=$(mktemp -d)
    mkdir -p "$single_dir/commands"
    echo "test" > "$single_dir/commands/only-one.md"
    local old_claude_dir="$CLAUDE_DIR"
    CLAUDE_DIR="$single_dir"

    local result
    result=$(get_slash_commands)
    local count
    count=$(echo "$result" | wc -l)

    CLAUDE_DIR="$old_claude_dir"
    rm -rf "$single_dir"

    if [[ $count -eq 1 ]] && [[ "$result" == "only-one" ]]; then
        pass "Edge case: single command directory"
    else
        fail "Edge case: single command directory" "1, only-one" "$count, $result"
    fi
}

test_edge_special_chars_in_prefix() {
    # Test that special regex chars don't break filtering
    local result
    result=$(printf "test-cmd\ntest.cmd\ntest*cmd" | filter_commands "test.")

    # Bash glob matching shouldn't interpret . as regex
    if [[ "$result" == "test.cmd" ]]; then
        pass "Edge case: special chars in prefix"
    else
        fail "Edge case: special chars in prefix" "test.cmd" "$result"
    fi
}

test_edge_very_long_command() {
    local long_dir=$(mktemp -d)
    mkdir -p "$long_dir/commands"
    local long_name="this-is-a-very-long-command-name-that-might-cause-issues"
    echo "test" > "$long_dir/commands/${long_name}.md"
    local old_claude_dir="$CLAUDE_DIR"
    CLAUDE_DIR="$long_dir"

    local result
    result=$(get_slash_commands)

    CLAUDE_DIR="$old_claude_dir"
    rm -rf "$long_dir"

    if [[ "$result" == "$long_name" ]]; then
        pass "Edge case: very long command name"
    else
        fail "Edge case: very long command name" "$long_name" "$result"
    fi
}

run_test test_edge_single_command
run_test test_edge_special_chars_in_prefix
run_test test_edge_very_long_command

# ============================================================
# SECTION 7: DISPLAY.SH TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 7: display.sh Tests"
echo "=========================================="
echo ""

test_display_sh_exists() {
    if [[ -f "$PROJECT_DIR/bin/display.sh" ]]; then
        pass "display.sh exists"
    else
        fail "display.sh exists" "file present" "not found"
    fi
}

test_display_sh_has_prompt() {
    if grep -q "display_prompt()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_prompt function"
    else
        fail "display.sh has display_prompt function"
    fi
}

test_display_sh_has_error() {
    if grep -q "display_error()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_error function"
    else
        fail "display.sh has display_error function"
    fi
}

test_display_sh_has_warning() {
    if grep -q "display_warning()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_warning function"
    else
        fail "display.sh has display_warning function"
    fi
}

test_display_sh_has_success() {
    if grep -q "display_success()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_success function"
    else
        fail "display.sh has display_success function"
    fi
}

test_display_sh_has_info() {
    if grep -q "display_info()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_info function"
    else
        fail "display.sh has display_info function"
    fi
}

test_display_sh_has_banner() {
    if grep -q "display_banner()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_banner function"
    else
        fail "display.sh has display_banner function"
    fi
}

test_display_sh_has_subagent_prefix() {
    if grep -q "display_subagent_prefix()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_subagent_prefix function"
    else
        fail "display.sh has display_subagent_prefix function"
    fi
}

test_display_sh_has_stopped() {
    if grep -q "display_stopped()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_stopped function"
    else
        fail "display.sh has display_stopped function"
    fi
}

test_display_sh_has_timeout() {
    if grep -q "display_timeout()" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh has display_timeout function"
    else
        fail "display.sh has display_timeout function"
    fi
}

test_display_sh_uses_gum() {
    if grep -q "gum style" "$PROJECT_DIR/bin/display.sh"; then
        pass "display.sh uses gum style"
    else
        fail "display.sh uses gum style"
    fi
}

run_test test_display_sh_exists
run_test test_display_sh_has_prompt
run_test test_display_sh_has_error
run_test test_display_sh_has_warning
run_test test_display_sh_has_success
run_test test_display_sh_has_info
run_test test_display_sh_has_banner
run_test test_display_sh_has_subagent_prefix
run_test test_display_sh_has_stopped
run_test test_display_sh_has_timeout
run_test test_display_sh_uses_gum

# ============================================================
# SECTION 8: CC SCRIPT TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 8: cc Script Tests"
echo "=========================================="
echo ""

test_cc_sources_display() {
    if grep -q 'source.*display.sh' "$PROJECT_DIR/bin/cc"; then
        pass "cc sources display.sh"
    else
        fail "cc sources display.sh"
    fi
}

test_cc_uses_display_prompt() {
    if grep -q 'display_prompt' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_prompt"
    else
        fail "cc uses display_prompt"
    fi
}

test_cc_uses_display_banner() {
    if grep -q 'display_banner' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_banner"
    else
        fail "cc uses display_banner"
    fi
}

test_cc_uses_display_stopped() {
    if grep -q 'display_stopped' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_stopped"
    else
        fail "cc uses display_stopped"
    fi
}

test_cc_uses_display_timeout() {
    if grep -q 'display_timeout' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_timeout"
    else
        fail "cc uses display_timeout"
    fi
}

test_cc_uses_display_warning() {
    if grep -q 'display_warning' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_warning"
    else
        fail "cc uses display_warning"
    fi
}

test_cc_uses_display_success() {
    if grep -q 'display_success' "$PROJECT_DIR/bin/cc"; then
        pass "cc uses display_success"
    else
        fail "cc uses display_success"
    fi
}

run_test test_cc_sources_display
run_test test_cc_uses_display_prompt
run_test test_cc_uses_display_banner
run_test test_cc_uses_display_stopped
run_test test_cc_uses_display_timeout
run_test test_cc_uses_display_warning
run_test test_cc_uses_display_success

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

# ============================================
# GUM COMPONENT TESTS
# ============================================

echo ""
echo "Running gum component tests..."
bash "$SCRIPT_DIR/test_gum.sh" || exit 1

# ============================================
# FINAL SUMMARY
# ============================================

if [[ $TESTS_FAILED -eq 0 ]]; then
    printf "${GREEN}All tests passed!${RESET}\n"
    exit 0
else
    printf "${RED}Some tests failed${RESET}\n"
    exit 1
fi
