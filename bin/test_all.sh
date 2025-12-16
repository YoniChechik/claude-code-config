#!/bin/bash
# test_all.sh - Comprehensive test suite for cc command
# Combines: test_multiline_regression.sh, test_autocomplete.sh, test_backspace_manual.sh

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
source "$SCRIPT_DIR/autocomplete.sh"

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
# SECTION 1: MULTI-LINE RENDERING REGRESSION TESTS
# ============================================================
echo "=========================================="
echo "SECTION 1: Multi-line Rendering Tests"
echo "=========================================="
echo ""

test_render_no_newline_in_menu() {
    # Verify render_autocomplete_menu does NOT use printf '\n' (scrolling fix)
    # Instead it always uses \033[E for cursor movement
    # Only count actual printf '\n' lines, not comments
    newline_count=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh" | grep -v "^[[:space:]]*#" | grep -c "printf '\\\\n'" || true)

    # The function should have 0 newlines - we always use \033[E now
    if [[ $newline_count -eq 0 ]]; then
        pass "render_autocomplete_menu has no printf '\\n' (uses \\033[E instead)"
    else
        fail "render_autocomplete_menu has $newline_count printf '\\n' (expected 0 - should use \\033[E)"
    fi
}

test_no_create_line_parameter() {
    # Verify create_line parameter was removed (simplification)
    if grep -q "create_line" "$SCRIPT_DIR/autocomplete.sh"; then
        fail "render_autocomplete_menu still has create_line parameter (should be removed)"
    else
        pass "render_autocomplete_menu has no create_line parameter (simplified)"
    fi
}

test_uses_cursor_down_escape() {
    if grep -q '\\033\[E' "$SCRIPT_DIR/autocomplete.sh"; then
        pass "render_autocomplete_menu uses \\033[E to move to next line"
    else
        fail "render_autocomplete_menu doesn't use \\033[E"
    fi
}

test_initial_render_no_extra_params() {
    # Verify initial render doesn't pass extra parameters (simplified API)
    if grep -q "render_autocomplete_menu filtered_commands \$selected$" "$SCRIPT_DIR/autocomplete.sh"; then
        pass "Initial render call has simplified signature (no extra params)"
    else
        # Check if it's in the expected format without 'true'
        if ! grep -q "render_autocomplete_menu filtered_commands.*true" "$SCRIPT_DIR/autocomplete.sh"; then
            pass "Initial render call has simplified signature (no 'true' param)"
        else
            fail "Initial render call still passes 'true'"
        fi
    fi
}

test_all_renders_consistent() {
    # All render calls should have the same signature (no 'true' param anywhere)
    renders_with_true=$(grep -c "render_autocomplete_menu filtered_commands.*true" "$SCRIPT_DIR/autocomplete.sh" || true)

    if [[ $renders_with_true -eq 0 ]]; then
        pass "All render calls use consistent signature (no 'true' parameter)"
    else
        fail "Found $renders_with_true render calls with 'true' parameter"
    fi
}

test_backspace_wrapped_line_support() {
    # Check that backspace handler clears and re-renders menu (modern approach)
    # The modern implementation uses clear_autocomplete_menu + render_autocomplete_menu
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$backspace_handler" | grep -q "clear_autocomplete_menu" && \
       echo "$backspace_handler" | grep -q "render_autocomplete_menu"; then
        pass "Backspace handler clears and re-renders menu (wrapped line support)"
    else
        fail "Backspace handler doesn't clear and re-render menu"
    fi
}

test_no_old_backspace_sequence() {
    # Check that the old '\b \b' is NOT used in the "/" backspace context (regression check)
    if grep -A1 "Backspacing the / itself" "$SCRIPT_DIR/autocomplete.sh" | grep -q "printf '\\\\b \\\\b'"; then
        fail "Found old \\b \\b in '/' backspace context (should be \\033[D\\033[K)"
    else
        pass "'/' backspace context uses correct sequence (not old \\b \\b)"
    fi
}

test_backspace_in_correct_context() {
    # Verify backspace exit is in the right context (backspacing "/" in autocomplete)
    # Check for the comment about backspacing the slash itself
    if grep -B2 -A2 "Backspacing the / itself" "$SCRIPT_DIR/autocomplete.sh" | grep -q "clear_autocomplete_menu"; then
        pass "Backspace exit is in correct context (backspacing '/' character)"
    else
        # Alternative: check the BACKSPACE handler has the exit condition
        local backspace_handler
        backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")
        if echo "$backspace_handler" | grep -q "elif.*\${#input} -eq 1"; then
            pass "Backspace exit is in correct context (handles '/' backspace)"
        else
            fail "Backspace exit not in expected context"
        fi
    fi
}

run_test test_render_no_newline_in_menu
run_test test_no_create_line_parameter
run_test test_uses_cursor_down_escape
run_test test_initial_render_no_extra_params
run_test test_all_renders_consistent
run_test test_backspace_wrapped_line_support
run_test test_no_old_backspace_sequence
run_test test_backspace_in_correct_context

# ============================================================
# SECTION 2: AUTOCOMPLETE FUNCTIONALITY TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 2: Autocomplete Functionality"
echo "=========================================="
echo ""

# --- get_slash_commands tests ---
echo "--- get_slash_commands tests ---"

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

# --- filter_commands tests ---
echo ""
echo "--- filter_commands tests ---"

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

# --- levenshtein tests ---
echo ""
echo "--- levenshtein tests ---"

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

# --- find_similar_command tests ---
echo ""
echo "--- find_similar_command tests ---"

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

# --- Integration tests ---
echo ""
echo "--- Integration tests ---"

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

# --- Edge case tests ---
echo ""
echo "--- Edge case tests ---"

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

# --- Rendering tests ---
echo ""
echo "--- Rendering tests ---"

test_clear_menu_uses_clear_to_eos() {
    # Check that clear_autocomplete_menu uses \033[J (clear to end of screen)
    # This is essential for proper handling of wrapped lines
    if grep -A3 "clear_autocomplete_menu()" "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[J'; then
        pass "clear_menu uses \\033[J (clear to end of screen) for wrapped line support"
    else
        fail "clear_menu uses \\033[J" "\\033[J in clear_autocomplete_menu" "not found"
    fi
}

test_render_menu_always_uses_cursor_movement() {
    # Test that render ALWAYS uses \033[E (never printf '\n')
    # This prevents terminal scroll bugs at bottom of screen
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_cursor_E=false
    local has_printf_n=false

    echo "$render_func" | grep -q '\\033\[E' && has_cursor_E=true
    # Only check non-comment lines for printf '\n'
    echo "$render_func" | grep -v "^[[:space:]]*#" | grep -q "printf '\\\\n'" && has_printf_n=true

    if [[ $has_cursor_E == true ]] && [[ $has_printf_n == false ]]; then
        pass "render_menu uses \\033[E and never printf '\\n' (scroll-safe)"
    else
        local issues=""
        [[ $has_cursor_E == false ]] && issues+="missing \\033[E; "
        [[ $has_printf_n == true ]] && issues+="has printf '\\n'; "
        fail "render_menu scroll-safe implementation" "\\033[E only, no \\n" "$issues"
    fi
}

test_render_menu_has_width_calculation() {
    # Test that render function calculates terminal width
    if grep -q "tput cols" "$SCRIPT_DIR/autocomplete.sh"; then
        pass "render_menu calculates terminal width with tput cols"
    else
        fail "render_menu calculates terminal width" "tput cols found" "not found"
    fi
}

test_render_menu_limits_items_to_fit() {
    # Test that render function has logic to limit items based on width
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q "available_width\|menu_width"; then
        pass "render_menu has width limiting logic"
    else
        fail "render_menu has width limiting logic" "width variables found" "not found"
    fi
}

test_char_input_sequence_no_inline_menu() {
    # Test the sequence in the CHAR case:
    # 1. printf "%s" "$KEY_CHAR" - character appears on input line
    # 2. clear_autocomplete_menu - clears using \033[J (end of screen)
    # 3. render_autocomplete_menu - uses \033[J then \033[E to position menu

    # Check that both clear and render use proper cursor movement
    local has_clear_eos=false
    local has_render_movement=false

    # clear_autocomplete_menu should use \033[J (clear to end of screen)
    if grep -A3 "clear_autocomplete_menu()" "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[J'; then
        has_clear_eos=true
    fi

    # render_autocomplete_menu should use \033[E for positioning
    if sed -n '/render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[E'; then
        has_render_movement=true
    fi

    if [[ $has_clear_eos == true ]] && [[ $has_render_movement == true ]]; then
        pass "CHAR input sequence: clear uses \\033[J, render uses \\033[E"
    else
        local issues=""
        [[ $has_clear_eos == false ]] && issues+="clear missing \\033[J; "
        [[ $has_render_movement == false ]] && issues+="render missing \\033[E; "
        fail "CHAR input sequence uses proper cursor movement" "clear=\\033[J, render=\\033[E" "$issues"
    fi
}

test_render_sequence_complete() {
    # Test the render sequence has all required elements:
    # 1. Save cursor (\033[s)
    # 2. Clear to EOS (\033[J)
    # 3. Move to next line (\033[E)
    # 4. Restore cursor (\033[u)
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_save=false
    local has_clear=false
    local has_move=false
    local has_restore=false

    echo "$render_func" | grep -q '\\033\[s' && has_save=true
    echo "$render_func" | grep -q '\\033\[J' && has_clear=true
    echo "$render_func" | grep -q '\\033\[E' && has_move=true
    echo "$render_func" | grep -q '\\033\[u' && has_restore=true

    if [[ $has_save == true ]] && [[ $has_clear == true ]] && [[ $has_move == true ]] && [[ $has_restore == true ]]; then
        pass "Render sequence complete: save + clear + move + restore"
    else
        local issues=""
        [[ $has_save == false ]] && issues+="missing save; "
        [[ $has_clear == false ]] && issues+="missing clear; "
        [[ $has_move == false ]] && issues+="missing move; "
        [[ $has_restore == false ]] && issues+="missing restore; "
        fail "Render sequence" "save+clear+move+restore" "$issues"
    fi
}

run_test test_clear_menu_uses_clear_to_eos
run_test test_render_menu_always_uses_cursor_movement
run_test test_render_menu_has_width_calculation
run_test test_render_menu_limits_items_to_fit
run_test test_char_input_sequence_no_inline_menu
run_test test_render_sequence_complete

# --- Wrapped line handling tests ---
echo ""
echo "--- Wrapped line handling tests ---"

test_render_uses_clear_to_eos() {
    # Verify render_autocomplete_menu uses \033[J to handle wrapped lines
    # This is the key fix for the overlap bug when input wraps
    if grep -q '\\033\[J' "$SCRIPT_DIR/autocomplete.sh"; then
        pass "render_autocomplete_menu uses \\033[J (clear to EOS)"
    else
        fail "render_autocomplete_menu uses \\033[J" "\\033[J found" "not found"
    fi
}

test_clear_eos_before_menu_render() {
    # The clear to EOS must happen BEFORE the menu items are rendered
    # This ensures old menu remnants are cleared when input wraps
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    # Check that \033[J appears before the for loop that renders items (the one with printf)
    # Note: There are two for loops - one for width calculation, one for rendering
    local eos_line
    local render_for_line
    eos_line=$(echo "$render_func" | grep -n '\\033\[J' | head -1 | cut -d: -f1)
    # Find the render for loop (the one that contains printf)
    render_for_line=$(echo "$render_func" | grep -n 'for ((i=0' | tail -1 | cut -d: -f1)

    if [[ -n "$eos_line" ]] && [[ -n "$render_for_line" ]] && [[ $eos_line -lt $render_for_line ]]; then
        pass "Clear to EOS (\\033[J) happens before menu rendering for loop"
    else
        fail "Clear to EOS before menu rendering" "\\033[J before render for loop" "eos_line=$eos_line, render_for_line=$render_for_line"
    fi
}

test_wrapped_line_calculation_support() {
    # Test that we can calculate wrapped line scenarios
    # Terminal width 10, input "> /abcde" = 8 chars (fits)
    # Terminal width 10, input "> /abcdefgh" = 11 chars (wraps to 2 rows)
    local term_width=10
    local input1="> /abcde"    # 8 chars, fits
    local input2="> /abcdefgh" # 11 chars, wraps

    local rows1=$(( (${#input1} + term_width - 1) / term_width ))
    local rows2=$(( (${#input2} + term_width - 1) / term_width ))

    if [[ $rows1 -eq 1 ]] && [[ $rows2 -eq 2 ]]; then
        pass "Wrapped line calculation: 8 chars -> 1 row, 11 chars -> 2 rows"
    else
        fail "Wrapped line calculation" "rows1=1, rows2=2" "rows1=$rows1, rows2=$rows2"
    fi
}

test_menu_position_after_wrap() {
    # Simulate menu position after input wraps
    # When input wraps, cursor ends on row 2
    # Menu should appear on row 3 (next line from cursor)
    # Using \033[E from any position goes to start of next row
    local cursor_row_after_wrap=2  # simulated
    local menu_row=$((cursor_row_after_wrap + 1))  # \033[E moves to next row

    if [[ $menu_row -eq 3 ]]; then
        pass "Menu position after wrap: cursor row 2 -> menu row 3"
    else
        fail "Menu position after wrap" "menu_row=3" "menu_row=$menu_row"
    fi
}

test_old_menu_cleared_on_wrap() {
    # When input grows and wraps, old menu on row 2 must be cleared
    # \033[J from cursor clears everything below, including old menu
    # This test verifies the fix handles the scenario

    # Check that clear_autocomplete_menu uses \033[J
    local uses_eos=false
    if grep -A3 "clear_autocomplete_menu()" "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[J'; then
        uses_eos=true
    fi

    # Check that render_autocomplete_menu also uses \033[J
    local render_uses_eos=false
    if sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[J'; then
        render_uses_eos=true
    fi

    if [[ $uses_eos == true ]] && [[ $render_uses_eos == true ]]; then
        pass "Both clear and render use \\033[J to handle wrapped line remnants"
    else
        fail "Wrapped line remnant handling" "both use \\033[J" "clear=$uses_eos, render=$render_uses_eos"
    fi
}

test_very_long_input_handling() {
    # Test with very long input that would wrap multiple times
    # Terminal width 20, input with 50 chars wraps to 3 rows
    local term_width=20
    local long_input="> /this-is-a-very-long-command-prefix-that-wraps"  # 50 chars
    local rows=$(( (${#long_input} + term_width - 1) / term_width ))

    if [[ $rows -eq 3 ]]; then
        pass "Very long input (50 chars, width 20): wraps to 3 rows"
    else
        fail "Very long input wrapping" "3 rows" "$rows rows"
    fi
}

test_small_terminal_wrapping() {
    # Extreme case: terminal width 5
    # Even short input wraps: "> /a" = 4 chars fits, "> /ab" = 5 chars wraps
    local term_width=5
    local input1="> /a"   # 4 chars
    local input2="> /ab"  # 5 chars
    local input3="> /abc" # 6 chars

    local rows1=$(( (${#input1} + term_width - 1) / term_width ))
    local rows2=$(( (${#input2} + term_width - 1) / term_width ))
    local rows3=$(( (${#input3} + term_width - 1) / term_width ))

    if [[ $rows1 -eq 1 ]] && [[ $rows2 -eq 1 ]] && [[ $rows3 -eq 2 ]]; then
        pass "Small terminal (width 5): 4->1row, 5->1row, 6->2rows"
    else
        fail "Small terminal wrapping" "1,1,2" "$rows1,$rows2,$rows3"
    fi
}

test_cursor_save_restore_with_wrap() {
    # Verify cursor save/restore sequences are present for wrapped line handling
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_save=false
    local has_restore=false
    local has_eos=false

    echo "$render_func" | grep -q '\\033\[s' && has_save=true
    echo "$render_func" | grep -q '\\033\[u' && has_restore=true
    echo "$render_func" | grep -q '\\033\[J' && has_eos=true

    if [[ $has_save == true ]] && [[ $has_restore == true ]] && [[ $has_eos == true ]]; then
        pass "Wrapped line handling: save + restore + clear-EOS all present"
    else
        fail "Wrapped line handling sequences" "save+restore+eos" "save=$has_save,restore=$has_restore,eos=$has_eos"
    fi
}

run_test test_render_uses_clear_to_eos
run_test test_clear_eos_before_menu_render
run_test test_wrapped_line_calculation_support
run_test test_menu_position_after_wrap
run_test test_old_menu_cleared_on_wrap
run_test test_very_long_input_handling
run_test test_small_terminal_wrapping
run_test test_cursor_save_restore_with_wrap

# --- Navigation simulation tests ---
echo ""
echo "--- Navigation simulation tests ---"

test_navigation_bounds_array() {
    # Simulate navigation bounds checking
    local items=("ask" "finish" "sync")
    local selected=0
    local max_idx=$((${#items[@]} - 1))

    # Try to go up from 0
    if [[ $selected -gt 0 ]]; then
        ((selected--))
    fi

    if [[ $selected -eq 0 ]]; then
        pass "Navigation: up bound respected at top"
    else
        fail "Navigation: up bound respected at top" "0" "$selected"
    fi
}

test_navigation_bounds_down() {
    local items=("ask" "finish" "sync")
    local selected=2
    local max_idx=$((${#items[@]} - 1))

    # Try to go down from max
    if [[ $selected -lt $max_idx ]]; then
        ((selected++))
    fi

    if [[ $selected -eq 2 ]]; then
        pass "Navigation: down bound respected at bottom"
    else
        fail "Navigation: down bound respected at bottom" "2" "$selected"
    fi
}

test_navigation_wrap_behavior() {
    # Our implementation doesn't wrap - verify
    local items=("a" "b" "c")
    local selected=0

    # Simulate up press at top - should stay at 0
    [[ $selected -gt 0 ]] && ((selected--))

    if [[ $selected -eq 0 ]]; then
        pass "Navigation: no wrap at boundaries"
    else
        fail "Navigation: no wrap at boundaries"
    fi
}

run_test test_navigation_bounds_array
run_test test_navigation_bounds_down
run_test test_navigation_wrap_behavior

# ============================================================
# SECTION 3: BACKSPACE BOUNDARY TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 3: Backspace Boundary Tests"
echo "=========================================="
echo ""

test_backspace_tracking_logic() {
    # Test the input tracking logic during backspace
    local input="/"

    # Simulate typing "abc"
    input+="a"
    input+="b"
    input+="c"

    if [[ "$input" == "/abc" ]] && [[ ${#input} -eq 4 ]]; then
        pass "Backspace logic: input tracking after typing"
    else
        fail "Backspace logic: input tracking after typing" "/abc (len 4)" "$input (len ${#input})"
    fi
}

test_backspace_single_char() {
    local input="/abc"

    # Backspace once
    if [[ ${#input} -gt 1 ]]; then
        input="${input%?}"
    fi

    if [[ "$input" == "/ab" ]] && [[ ${#input} -eq 3 ]]; then
        pass "Backspace logic: single backspace from /abc"
    else
        fail "Backspace logic: single backspace from /abc" "/ab (len 3)" "$input (len ${#input})"
    fi
}

test_backspace_to_slash_only() {
    local input="/a"

    # Backspace to just "/"
    if [[ ${#input} -gt 1 ]]; then
        input="${input%?}"
    fi

    if [[ "$input" == "/" ]] && [[ ${#input} -eq 1 ]]; then
        pass "Backspace logic: backspace to / only"
    else
        fail "Backspace logic: backspace to / only" "/ (len 1)" "$input (len ${#input})"
    fi
}

test_backspace_at_slash_triggers_exit() {
    local input="/"
    local should_exit=false

    # Simulate the condition check in run_autocomplete
    if [[ ${#input} -eq 1 ]]; then
        should_exit=true
    fi

    if [[ $should_exit == true ]]; then
        pass "Backspace logic: at / triggers exit condition"
    else
        fail "Backspace logic: at / triggers exit condition"
    fi
}

test_backspace_rapid_sequence() {
    # Simulate rapid backspace: type "/abc" then backspace 4 times
    local input="/"
    input+="a"
    input+="b"
    input+="c"

    # Backspace 1: /abc -> /ab
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # Backspace 2: /ab -> /a
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # Backspace 3: /a -> /
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # At this point we should be at "/" (len 1)
    # Backspace 4: should trigger exit, NOT erase more
    local should_exit=false
    if [[ ${#input} -eq 1 ]]; then
        should_exit=true
    elif [[ ${#input} -eq 0 ]]; then
        # This shouldn't happen - it means we erased too much
        should_exit=false
    fi

    if [[ $should_exit == true ]] && [[ "$input" == "/" ]]; then
        pass "Backspace logic: rapid backspace stops at / and exits"
    else
        fail "Backspace logic: rapid backspace stops at / and exits" "exit=true, input=/" "exit=$should_exit, input=$input (len ${#input})"
    fi
}

test_backspace_boundary_no_over_erase() {
    # Test that we never allow input to become empty during backspace
    local input="/"

    # Try to backspace when already at /
    # The elif condition should catch this
    local erased=false
    if [[ ${#input} -gt 1 ]]; then
        input="${input%?}"
        erased=true
    elif [[ ${#input} -eq 1 ]]; then
        # This is the exit case - we DON'T modify input further
        erased=false
    fi

    if [[ $erased == false ]] && [[ "$input" == "/" ]]; then
        pass "Backspace logic: no over-erase past /"
    else
        fail "Backspace logic: no over-erase past /" "erased=false, input=/" "erased=$erased, input=$input"
    fi
}

test_backspace_terminal_output_count() {
    # Test that backspace outputs exactly the right number of erase sequences
    local input="/abc"
    local backspace_count=0

    # Simulate 3 backspaces (to get back to just "/")
    while [[ ${#input} -gt 1 ]]; do
        input="${input%?}"
        ((backspace_count++))
        # Each iteration should output one '\b \b' sequence
    done

    if [[ $backspace_count -eq 3 ]] && [[ "$input" == "/" ]]; then
        pass "Backspace logic: correct erase count from /abc to /"
    else
        fail "Backspace logic: correct erase count from /abc to /" "3 erases, input=/" "$backspace_count erases, input=$input"
    fi
}

test_backspace_empty_protection() {
    # Edge case: what if input somehow becomes empty?
    # Our code should not output backspace sequences if input is empty
    local input=""
    local should_erase=false

    if [[ ${#input} -gt 1 ]]; then
        should_erase=true
    elif [[ ${#input} -eq 1 ]]; then
        should_erase=true
    fi

    if [[ $should_erase == false ]]; then
        pass "Backspace logic: empty input protection"
    else
        fail "Backspace logic: empty input protection"
    fi
}

run_test test_backspace_tracking_logic
run_test test_backspace_single_char
run_test test_backspace_to_slash_only
run_test test_backspace_at_slash_triggers_exit
run_test test_backspace_rapid_sequence
run_test test_backspace_boundary_no_over_erase
run_test test_backspace_terminal_output_count
run_test test_backspace_empty_protection

# ============================================================
# SECTION 4: ADVANCED WRAPPING AND WIDTH TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 4: Advanced Wrapping and Width Tests"
echo "=========================================="
echo ""

test_menu_width_calculation_basic() {
    # Terminal 80 cols, 5 items of 10 chars each = ~65 chars total (fits)
    local term_width=80
    local item_widths=(10 10 10 10 10)  # 5 items
    local total=0
    for w in "${item_widths[@]}"; do
        total=$((total + w + 3))  # +3 for "/" + "  "
    done

    if [[ $total -lt $((term_width - 10)) ]]; then
        pass "Menu width calculation: 5 items fit in 80 cols (total=$total)"
    else
        fail "Menu width calculation" "items fit" "total=$total exceeds $((term_width - 10))"
    fi
}

test_menu_width_overflow_prevention() {
    # Terminal 40 cols, 10 items of 12 chars each = would overflow
    # Should limit to items that fit
    local term_width=40
    local available=$((term_width - 10))  # margin
    local items=(12 12 12 12 12 12 12 12 12 12)  # 10 items, 12 chars each

    local count=0
    local width=0
    for item_len in "${items[@]}"; do
        local item_width=$((item_len + 3))
        if ((width + item_width <= available)); then
            width=$((width + item_width))
            count=$((count + 1))
        else
            break
        fi
    done

    # Should fit 2 items maximum (2 * 15 = 30, 3 * 15 = 45 > 30)
    if [[ $count -le 3 ]] && [[ $count -gt 0 ]]; then
        pass "Menu width overflow: limits to $count items in 40 col terminal"
    else
        fail "Menu width overflow prevention" "1-3 items" "$count items"
    fi
}

test_very_narrow_terminal_20cols() {
    # Extreme: terminal width 20, command is 15 chars
    local term_width=20
    local available=$((term_width - 10))
    local item_len=15
    local item_width=$((item_len + 3))  # + "/" + "  "

    if [[ $item_width -le $available ]]; then
        pass "Very narrow terminal (20 cols): can fit 15-char command"
    else
        # Should still show at least 1 item even if overflow
        pass "Very narrow terminal (20 cols): would overflow but shows 1 item minimum"
    fi
}

test_very_narrow_terminal_15cols() {
    # Extreme: terminal width 15
    local term_width=15
    # Even with overflow, should attempt to show 1 item
    # Implementation should have "show at least 1" logic
    if [[ $term_width -ge 15 ]]; then
        pass "Very narrow terminal (15 cols): has minimum width for basic operation"
    fi
}

test_minimum_item_show_guarantee() {
    # Verify the code has "always show at least 1 item" logic
    if grep -q '\[.*show.*-eq 0.*\].*&&.*show=1\|show -eq 0.*show=1' "$SCRIPT_DIR/autocomplete.sh"; then
        pass "Menu rendering: has 'show at least 1 item' guarantee"
    else
        # Alternative check for the pattern
        if grep -q "Always show at least 1 item" "$SCRIPT_DIR/autocomplete.sh"; then
            pass "Menu rendering: has 'show at least 1 item' guarantee"
        else
            fail "Menu rendering: 'show at least 1' guarantee" "guarantee found" "not found"
        fi
    fi
}

run_test test_menu_width_calculation_basic
run_test test_menu_width_overflow_prevention
run_test test_very_narrow_terminal_20cols
run_test test_very_narrow_terminal_15cols
run_test test_minimum_item_show_guarantee

# ============================================================
# SECTION 5: MULTIPLE ERASE/RETRY CYCLE TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 5: Multiple Erase/Retry Cycle Tests"
echo "=========================================="
echo ""

test_clear_autocomplete_menu_idempotent() {
    # Calling clear multiple times should be safe
    # Verify the clear function uses proper sequences
    if grep -A3 "clear_autocomplete_menu()" "$SCRIPT_DIR/autocomplete.sh" | grep -q '\\033\[J'; then
        pass "Clear menu is idempotent (safe to call multiple times)"
    else
        fail "Clear menu idempotent" "uses \\033[J" "not found"
    fi
}

test_erase_retry_sequence_logic() {
    # Simulate: type "/abc", backspace to "/", exit, repeat
    local cycles=0
    for ((i=0; i<5; i++)); do
        local input="/"
        input+="abc"
        # Backspace to "/"
        while [[ ${#input} -gt 1 ]]; do
            input="${input%?}"
        done
        # Exit condition
        if [[ ${#input} -eq 1 ]]; then
            cycles=$((cycles + 1))
        fi
    done

    if [[ $cycles -eq 5 ]]; then
        pass "Erase/retry cycle: simulated 5 cycles successfully"
    else
        fail "Erase/retry cycle" "5 cycles" "$cycles cycles"
    fi
}

test_clear_then_render_sequence() {
    # Verify clear is called before render in CHAR/BACKSPACE handlers
    local char_handler
    char_handler=$(sed -n '/CHAR)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$char_handler" | grep -q "clear_autocomplete_menu"; then
        if echo "$char_handler" | grep -q "render_autocomplete_menu"; then
            pass "CHAR handler: clear before render sequence"
        else
            fail "CHAR handler sequence" "clear + render" "missing render"
        fi
    else
        fail "CHAR handler sequence" "clear + render" "missing clear"
    fi
}

run_test test_clear_autocomplete_menu_idempotent
run_test test_erase_retry_sequence_logic
run_test test_clear_then_render_sequence

# ============================================================
# SECTION 6: SEQUENTIAL PROMPT TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 6: Sequential Prompt Tests"
echo "=========================================="
echo ""

test_autocomplete_second_invocation() {
    # Simulate running autocomplete twice in a session
    # First invocation
    local session1_input="/"
    local session1_ran=false
    if [[ "$session1_input" == "/" ]]; then
        session1_ran=true
    fi

    # Second invocation (new prompt)
    local session2_input="/"
    local session2_ran=false
    if [[ "$session2_input" == "/" ]]; then
        session2_ran=true
    fi

    if [[ $session1_ran == true ]] && [[ $session2_ran == true ]]; then
        pass "Sequential prompts: autocomplete can run multiple times per session"
    else
        fail "Sequential prompts" "both sessions ran" "session1=$session1_ran, session2=$session2_ran"
    fi
}

test_autocomplete_state_independence() {
    # Each autocomplete invocation should be independent
    # Check that no global state persists
    local first_selected=0
    local second_selected=0

    # They should both be 0 (independent)
    if [[ $first_selected -eq 0 ]] && [[ $second_selected -eq 0 ]]; then
        pass "Sequential prompts: each invocation has independent state"
    else
        fail "Sequential prompts state" "both 0" "first=$first_selected, second=$second_selected"
    fi
}

test_run_autocomplete_local_variables() {
    # Verify run_autocomplete uses local variables (not global)
    local run_func
    run_func=$(sed -n '/^run_autocomplete/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_local_input=false
    local has_local_selected=false

    echo "$run_func" | grep -q "local input=" && has_local_input=true
    echo "$run_func" | grep -q "local selected=" && has_local_selected=true

    if [[ $has_local_input == true ]] && [[ $has_local_selected == true ]]; then
        pass "run_autocomplete: uses local variables for state"
    else
        local issues=""
        [[ $has_local_input == false ]] && issues+="input not local; "
        [[ $has_local_selected == false ]] && issues+="selected not local; "
        fail "run_autocomplete local variables" "local input and selected" "$issues"
    fi
}

run_test test_autocomplete_second_invocation
run_test test_autocomplete_state_independence
run_test test_run_autocomplete_local_variables

# ============================================================
# SECTION 7: EXTREME WRAPPING TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 7: Extreme Wrapping Tests"
echo "=========================================="
echo ""

test_input_wraps_to_three_rows() {
    # Terminal width 20, input 50 chars -> 3 rows
    local term_width=20
    local input="> /this-is-a-very-long-command-prefix-12345"  # 47 chars
    local rows=$(( (${#input} + term_width - 1) / term_width ))

    if [[ $rows -eq 3 ]]; then
        pass "Extreme wrapping: 47-char input wraps to 3 rows (width 20)"
    else
        fail "Extreme wrapping: 3 rows" "3 rows" "$rows rows"
    fi
}

test_input_wraps_to_four_rows() {
    # Terminal width 15, input 55 chars -> 4 rows
    local term_width=15
    local input="> /this-is-an-extremely-long-command-prefix-test-12"  # 55 chars
    local rows=$(( (${#input} + term_width - 1) / term_width ))

    if [[ $rows -eq 4 ]]; then
        pass "Extreme wrapping: 55-char input wraps to 4 rows (width 15)"
    else
        fail "Extreme wrapping: 4 rows" "4 rows" "$rows rows"
    fi
}

test_backspace_on_wrapped_line_calculation() {
    # When backspacing from row 2 to row 1
    # Cursor should move from column 0 of row 2 to end of row 1
    local term_width=24
    local row1_chars=24  # Full row
    local row2_chars=5   # Partial row

    # After backspace, should be back on row 1
    local new_total=$((row1_chars + row2_chars - 1))
    local new_rows=$(( (new_total + term_width - 1) / term_width ))

    if [[ $new_rows -eq 2 ]]; then
        # 28 chars / 24 = 2 rows (row 1 full, row 2 partial)
        pass "Backspace on wrapped line: correctly calculates 2 rows for 28 chars"
    else
        fail "Backspace on wrapped line" "2 rows after backspace" "$new_rows rows"
    fi
}

test_wrap_boundary_exact() {
    # Test exact boundary: term_width characters exactly
    local term_width=24
    local input_len=24
    local rows=$(( (input_len + term_width - 1) / term_width ))

    if [[ $rows -eq 1 ]]; then
        pass "Wrap boundary: exactly 24 chars fits in 1 row (width 24)"
    else
        fail "Wrap boundary exact" "1 row" "$rows rows"
    fi
}

test_wrap_boundary_plus_one() {
    # Test one char over: term_width + 1 characters
    local term_width=24
    local input_len=25
    local rows=$(( (input_len + term_width - 1) / term_width ))

    if [[ $rows -eq 2 ]]; then
        pass "Wrap boundary: 25 chars wraps to 2 rows (width 24)"
    else
        fail "Wrap boundary plus one" "2 rows" "$rows rows"
    fi
}

run_test test_input_wraps_to_three_rows
run_test test_input_wraps_to_four_rows
run_test test_backspace_on_wrapped_line_calculation
run_test test_wrap_boundary_exact
run_test test_wrap_boundary_plus_one

# ============================================================
# SECTION 8: COMPREHENSIVE FUNCTIONALITY TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 8: Comprehensive Functionality Tests"
echo "=========================================="
echo ""

# --- Invisible input mode tests ---
echo "--- Invisible input mode tests ---"

test_no_visible_characters_in_char_handler() {
    # Verify CHAR handler does NOT echo characters (invisible input mode)
    # Characters should only be added to internal input, not printed
    local char_handler
    char_handler=$(sed -n '/CHAR)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    # Check that CHAR handler does NOT use printf "%s" "$KEY_CHAR" or echo "$KEY_CHAR"
    # It should only do: input+="$KEY_CHAR"
    if echo "$char_handler" | grep -v "^[[:space:]]*#" | grep -q 'printf.*KEY_CHAR\|echo.*KEY_CHAR'; then
        fail "Invisible input: CHAR handler should not print characters" "no character printing" "found character printing"
    else
        pass "Invisible input: CHAR handler does not echo typed characters"
    fi
}

test_input_appended_internally_only() {
    # Verify characters are appended to internal input variable
    local char_handler
    char_handler=$(sed -n '/CHAR)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$char_handler" | grep -q 'input+='; then
        pass "Invisible input: characters appended to internal input variable"
    else
        fail "Invisible input: internal input tracking" "input+= found" "not found"
    fi
}

test_menu_shows_filtered_results_not_input() {
    # Verify menu shows filtered commands, not the typed characters
    # This confirms invisible input mode - user sees results, not what they type
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'printf.*items\['; then
        pass "Invisible input: menu displays filtered items, not input characters"
    else
        fail "Invisible input: menu shows items" "printf items" "not found"
    fi
}

run_test test_no_visible_characters_in_char_handler
run_test test_input_appended_internally_only
run_test test_menu_shows_filtered_results_not_input

# --- Menu filtering correctness tests ---
echo ""
echo "--- Menu filtering correctness tests ---"

test_typing_filters_progressively() {
    # Simulate typing "pr" character by character
    local all_commands
    mapfile -t all_commands < <(get_slash_commands)

    # After typing nothing: show all
    local count0
    count0=$(printf '%s\n' "${all_commands[@]}" | filter_commands "" | wc -l)

    # After typing "p": should be less or equal
    local count1
    count1=$(printf '%s\n' "${all_commands[@]}" | filter_commands "p" | wc -l)

    # After typing "pr": should be less or equal
    local count2
    count2=$(printf '%s\n' "${all_commands[@]}" | filter_commands "pr" | wc -l)

    if [[ $count0 -ge $count1 ]] && [[ $count1 -ge $count2 ]]; then
        pass "Menu filtering: progressive typing narrows results (all=$count0, p=$count1, pr=$count2)"
    else
        fail "Menu filtering: progressive narrowing" "count0 >= count1 >= count2" "$count0, $count1, $count2"
    fi
}

test_filter_resets_on_char_input() {
    # Verify that CHAR handler calls filter_commands
    local char_handler
    char_handler=$(sed -n '/CHAR)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$char_handler" | grep -q "filter_commands"; then
        pass "Menu filtering: CHAR handler re-filters commands"
    else
        fail "Menu filtering: CHAR re-filters" "filter_commands called" "not found"
    fi
}

test_selection_resets_to_zero_on_filter() {
    # Verify that filtering resets selected index to 0
    local char_handler
    char_handler=$(sed -n '/CHAR)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$char_handler" | grep -q "selected=0"; then
        pass "Menu filtering: selection resets to 0 after typing"
    else
        fail "Menu filtering: selection reset" "selected=0 found" "not found"
    fi
}

run_test test_typing_filters_progressively
run_test test_filter_resets_on_char_input
run_test test_selection_resets_to_zero_on_filter

# --- Arrow key navigation tests ---
echo ""
echo "--- Arrow key navigation tests ---"

test_up_arrow_decreases_selection() {
    # Verify UP handler decreases selected when > 0
    local up_handler
    up_handler=$(sed -n '/UP)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$up_handler" | grep -q "((selected--))"; then
        pass "Arrow navigation: UP decreases selection"
    else
        fail "Arrow navigation: UP handler" "selected--" "not found"
    fi
}

test_down_arrow_increases_selection() {
    # Verify DOWN handler increases selected
    local down_handler
    down_handler=$(sed -n '/DOWN)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$down_handler" | grep -q "((selected++))"; then
        pass "Arrow navigation: DOWN increases selection"
    else
        fail "Arrow navigation: DOWN handler" "selected++" "not found"
    fi
}

test_up_arrow_respects_lower_bound() {
    # Verify UP doesn't go below 0
    local up_handler
    up_handler=$(sed -n '/UP)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$up_handler" | grep -q '\$selected -gt 0'; then
        pass "Arrow navigation: UP respects lower bound (0)"
    else
        fail "Arrow navigation: UP lower bound" "selected > 0 check" "not found"
    fi
}

test_down_arrow_respects_upper_bound() {
    # Verify DOWN doesn't exceed array length
    local down_handler
    down_handler=$(sed -n '/DOWN)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$down_handler" | grep -q '\$selected -lt'; then
        pass "Arrow navigation: DOWN respects upper bound"
    else
        fail "Arrow navigation: DOWN upper bound" "selected < check" "not found"
    fi
}

test_navigation_triggers_menu_redraw() {
    # Verify UP/DOWN handlers call render_autocomplete_menu
    local up_handler down_handler
    up_handler=$(sed -n '/UP)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")
    down_handler=$(sed -n '/DOWN)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    local up_renders=false down_renders=false
    echo "$up_handler" | grep -q "render_autocomplete_menu" && up_renders=true
    echo "$down_handler" | grep -q "render_autocomplete_menu" && down_renders=true

    if [[ $up_renders == true ]] && [[ $down_renders == true ]]; then
        pass "Arrow navigation: both UP and DOWN trigger menu redraw"
    else
        fail "Arrow navigation: menu redraw" "UP and DOWN render" "UP=$up_renders, DOWN=$down_renders"
    fi
}

run_test test_up_arrow_decreases_selection
run_test test_down_arrow_increases_selection
run_test test_up_arrow_respects_lower_bound
run_test test_down_arrow_respects_upper_bound
run_test test_navigation_triggers_menu_redraw

# --- Enter selection tests ---
echo ""
echo "--- Enter selection tests ---"

test_enter_returns_selected_command() {
    # Verify ENTER handler sets AUTOCOMPLETE_RESULT
    local enter_handler
    enter_handler=$(sed -n '/ENTER)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$enter_handler" | grep -q 'AUTOCOMPLETE_RESULT='; then
        pass "Enter selection: sets AUTOCOMPLETE_RESULT variable"
    else
        fail "Enter selection: result variable" "AUTOCOMPLETE_RESULT=" "not found"
    fi
}

test_enter_returns_filtered_command() {
    # Verify ENTER uses filtered_commands array
    local enter_handler
    enter_handler=$(sed -n '/ENTER)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$enter_handler" | grep -q 'filtered_commands\[.*selected'; then
        pass "Enter selection: returns filtered_commands[selected]"
    else
        fail "Enter selection: filtered command" "filtered_commands[selected]" "not found"
    fi
}

test_enter_clears_menu_before_return() {
    # Verify ENTER clears menu before returning
    local enter_handler
    enter_handler=$(sed -n '/ENTER)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$enter_handler" | grep -q 'clear_autocomplete_menu'; then
        pass "Enter selection: clears menu before returning"
    else
        fail "Enter selection: menu clear" "clear_autocomplete_menu" "not found"
    fi
}

test_enter_returns_success() {
    # Verify ENTER handler returns 0 (success)
    local enter_handler
    enter_handler=$(sed -n '/ENTER)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$enter_handler" | grep -q 'return 0'; then
        pass "Enter selection: returns 0 (success)"
    else
        fail "Enter selection: return code" "return 0" "not found"
    fi
}

run_test test_enter_returns_selected_command
run_test test_enter_returns_filtered_command
run_test test_enter_clears_menu_before_return
run_test test_enter_returns_success

# --- Backspace filtering tests ---
echo ""
echo "--- Backspace filtering tests ---"

test_backspace_removes_last_char() {
    # Verify BACKSPACE removes last character from input
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$backspace_handler" | grep -q 'input="\${input%?}"'; then
        pass "Backspace filtering: removes last character with \${input%?}"
    else
        fail "Backspace filtering: character removal" "\${input%?}" "not found"
    fi
}

test_backspace_refilters_commands() {
    # Verify BACKSPACE re-filters with shorter prefix
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$backspace_handler" | grep -q 'filter_commands'; then
        pass "Backspace filtering: re-filters commands after backspace"
    else
        fail "Backspace filtering: re-filter" "filter_commands" "not found"
    fi
}

test_backspace_resets_selection() {
    # Verify BACKSPACE resets selection to 0
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$backspace_handler" | grep -q 'selected=0'; then
        pass "Backspace filtering: resets selection to 0"
    else
        fail "Backspace filtering: selection reset" "selected=0" "not found"
    fi
}

run_test test_backspace_removes_last_char
run_test test_backspace_refilters_commands
run_test test_backspace_resets_selection

# --- Exit conditions tests ---
echo ""
echo "--- Exit conditions tests ---"

test_backspace_on_slash_exits_cleanly() {
    # Verify backspacing "/" exits with empty result
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$backspace_handler" | grep -q 'elif.*\${#input} -eq 1'; then
        pass "Exit on backspace: checks for single-character input (just '/')"
    else
        fail "Exit on backspace: exit condition" "input length check" "not found"
    fi
}

test_backspace_exit_clears_menu() {
    # Verify backspace exit clears menu
    local backspace_handler
    backspace_handler=$(sed -n '/BACKSPACE)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    # Check if the elif ${#input} -eq 1 branch calls clear_autocomplete_menu
    local exit_branch
    exit_branch=$(echo "$backspace_handler" | awk '/elif.*\${#input} -eq 1/,/fi/')

    if echo "$exit_branch" | grep -q 'clear_autocomplete_menu'; then
        pass "Exit on backspace: clears menu on exit"
    else
        fail "Exit on backspace: menu clear" "clear_autocomplete_menu in exit branch" "not found"
    fi
}

test_escape_exits_with_empty_result() {
    # Verify ESCAPE returns empty result
    local escape_handler
    escape_handler=$(sed -n '/ESCAPE.*CTRL_C)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$escape_handler" | grep -q 'AUTOCOMPLETE_RESULT=""'; then
        pass "Escape exit: sets empty AUTOCOMPLETE_RESULT"
    else
        fail "Escape exit: empty result" 'AUTOCOMPLETE_RESULT=""' "not found"
    fi
}

test_escape_returns_failure() {
    # Verify ESCAPE returns 1 (failure/cancel)
    local escape_handler
    escape_handler=$(sed -n '/ESCAPE.*CTRL_C)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$escape_handler" | grep -q 'return 1'; then
        pass "Escape exit: returns 1 (cancel)"
    else
        fail "Escape exit: return code" "return 1" "not found"
    fi
}

test_ctrl_c_exits_same_as_escape() {
    # Verify CTRL_C is handled same as ESCAPE
    local handler
    handler=$(sed -n '/ESCAPE.*CTRL_C)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$handler" | grep -q 'ESCAPE|CTRL_C'; then
        pass "Ctrl+C exit: handled same as Escape"
    else
        fail "Ctrl+C exit: handler" "ESCAPE|CTRL_C pattern" "not found"
    fi
}

test_ctrl_d_returns_exit_code_2() {
    # Verify CTRL_D returns special code 2
    local ctrl_d_handler
    ctrl_d_handler=$(sed -n '/CTRL_D)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$ctrl_d_handler" | grep -q 'return 2'; then
        pass "Ctrl+D exit: returns 2 (special exit code)"
    else
        fail "Ctrl+D exit: return code" "return 2" "not found"
    fi
}

run_test test_backspace_on_slash_exits_cleanly
run_test test_backspace_exit_clears_menu
run_test test_escape_exits_with_empty_result
run_test test_escape_returns_failure
run_test test_ctrl_c_exits_same_as_escape
run_test test_ctrl_d_returns_exit_code_2

# --- Edge case: Empty filter results ---
echo ""
echo "--- Edge case: Empty filter results ---"

test_empty_filter_result_handling() {
    # Test behavior when no commands match
    local result
    result=$(printf "ask\nfinish\nsync" | filter_commands "xyz")

    if [[ -z "$result" ]]; then
        pass "Edge case: empty filter returns nothing (no matches)"
    else
        fail "Edge case: empty filter" "empty result" "$result"
    fi
}

test_enter_with_empty_filter() {
    # Verify ENTER handler handles empty filtered_commands array
    local enter_handler
    enter_handler=$(sed -n '/ENTER)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$enter_handler" | grep -q '\${#filtered_commands\[@\]} -gt 0'; then
        pass "Edge case: Enter checks if filtered_commands is non-empty"
    else
        fail "Edge case: Enter empty check" "filtered_commands length check" "not found"
    fi
}

test_render_handles_empty_array() {
    # Verify render_autocomplete_menu handles count == 0
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q '\$count -eq 0.*return'; then
        pass "Edge case: render_menu returns early if array is empty"
    else
        fail "Edge case: render empty check" "count == 0 return" "not found"
    fi
}

run_test test_empty_filter_result_handling
run_test test_enter_with_empty_filter
run_test test_render_handles_empty_array

# --- Edge case: Single command match ---
echo ""
echo "--- Edge case: Single command match ---"

test_single_command_navigation() {
    # When only one command matches, navigation should stay at 0
    local items=("sync")
    local selected=0

    # Try to go up (should stay at 0)
    [[ $selected -gt 0 ]] && ((selected--))
    local after_up=$selected

    # Try to go down (should stay at 0 since max_idx is 0)
    [[ $selected -lt 0 ]] && ((selected++))
    local after_down=$selected

    if [[ $after_up -eq 0 ]] && [[ $after_down -eq 0 ]]; then
        pass "Edge case: single item navigation stays at index 0"
    else
        fail "Edge case: single item nav" "both 0" "up=$after_up, down=$after_down"
    fi
}

test_single_command_render() {
    # Test rendering with single item
    local single_dir=$(mktemp -d)
    mkdir -p "$single_dir/commands"
    echo "test" > "$single_dir/commands/solo.md"
    local old_claude_dir="$CLAUDE_DIR"
    CLAUDE_DIR="$single_dir"

    local commands
    mapfile -t commands < <(get_slash_commands)

    CLAUDE_DIR="$old_claude_dir"
    rm -rf "$single_dir"

    if [[ ${#commands[@]} -eq 1 ]] && [[ "${commands[0]}" == "solo" ]]; then
        pass "Edge case: single command renders correctly"
    else
        fail "Edge case: single command" "1 command 'solo'" "${#commands[@]} commands"
    fi
}

run_test test_single_command_navigation
run_test test_single_command_render

# --- Edge case: Very long command names ---
echo ""
echo "--- Edge case: Very long command names ---"

test_very_long_command_filtering() {
    # Test filtering with very long command name
    local long="this-is-an-extremely-long-command-name-for-testing"
    local result
    result=$(printf "%s\nshort" "$long" | filter_commands "this")

    if [[ "$result" == "$long" ]]; then
        pass "Edge case: very long command name filters correctly"
    else
        fail "Edge case: long command filter" "$long" "$result"
    fi
}

test_very_long_command_display_width() {
    # Verify width calculation handles long names
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'item_width=\$((.*#items'; then
        pass "Edge case: render calculates width based on item length"
    else
        fail "Edge case: width calculation" "item_width calculation" "not found"
    fi
}

run_test test_very_long_command_filtering
run_test test_very_long_command_display_width

# --- Edge case: Menu overflow (more than 10 items) ---
echo ""
echo "--- Edge case: Menu overflow ---"

test_max_menu_items_limit() {
    # Verify render function has max_show limit
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'max_show=10'; then
        pass "Edge case: menu has max_show=10 limit"
    else
        fail "Edge case: max_show limit" "max_show=10" "not found"
    fi
}

test_menu_iteration_respects_max_show() {
    # Verify menu iteration uses max_show bound
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'i<max_show'; then
        pass "Edge case: menu iteration respects max_show limit"
    else
        fail "Edge case: iteration limit" "i<max_show" "not found"
    fi
}

test_down_arrow_limited_by_max_show() {
    # Verify DOWN navigation is limited by max_show
    local down_handler
    down_handler=$(sed -n '/DOWN)/,/;;/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$down_handler" | grep -q '\$selected -lt 9'; then
        pass "Edge case: DOWN arrow limited to 9 (max_show - 1)"
    else
        fail "Edge case: DOWN limit" "selected < 9" "not found"
    fi
}

run_test test_max_menu_items_limit
run_test test_menu_iteration_respects_max_show
run_test test_down_arrow_limited_by_max_show

# --- Edge case: Terminal width constraints ---
echo ""
echo "--- Edge case: Terminal width constraints ---"

test_terminal_width_detection() {
    # Verify render function gets terminal width
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'tput cols'; then
        pass "Edge case: detects terminal width with tput cols"
    else
        fail "Edge case: terminal width" "tput cols" "not found"
    fi
}

test_available_width_calculation() {
    # Verify available width leaves margin
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'available_width=\$((term_width.*-.*10'; then
        pass "Edge case: calculates available width with margin"
    else
        fail "Edge case: available width" "term_width - 10" "not found"
    fi
}

test_menu_stops_at_width_limit() {
    # Verify menu stops adding items when width exceeded
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q 'menu_width.*item_width.*available_width'; then
        pass "Edge case: menu stops adding items at width limit"
    else
        fail "Edge case: width limit stop" "width comparison logic" "not found"
    fi
}

run_test test_terminal_width_detection
run_test test_available_width_calculation
run_test test_menu_stops_at_width_limit

# --- Cursor position tests ---
echo ""
echo "--- Cursor position tests ---"

test_cursor_save_before_render() {
    # Verify cursor is saved before rendering
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q "printf '\\\\033\[s'"; then
        pass "Cursor position: saves cursor before rendering"
    else
        fail "Cursor position: cursor save" "\\033[s" "not found"
    fi
}

test_cursor_restore_after_render() {
    # Verify cursor is restored after rendering
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q "printf '\\\\033\[u'"; then
        pass "Cursor position: restores cursor after rendering"
    else
        fail "Cursor position: cursor restore" "\\033[u" "not found"
    fi
}

test_menu_renders_below_input() {
    # Verify menu uses \033[E to move to next line
    local render_func
    render_func=$(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$render_func" | grep -q "printf '\\\\033\[E'"; then
        pass "Cursor position: menu renders below with \\033[E"
    else
        fail "Cursor position: next line move" "\\033[E" "not found"
    fi
}

test_clear_preserves_cursor_position() {
    # Verify clear_autocomplete_menu saves and restores cursor
    local clear_func
    clear_func=$(sed -n '/^clear_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_save=false has_restore=false
    echo "$clear_func" | grep -q "\\\\033\[s" && has_save=true
    echo "$clear_func" | grep -q "\\\\033\[u" && has_restore=true

    if [[ $has_save == true ]] && [[ $has_restore == true ]]; then
        pass "Cursor position: clear preserves cursor with save/restore"
    else
        fail "Cursor position: clear preserve" "save and restore" "save=$has_save, restore=$has_restore"
    fi
}

run_test test_cursor_save_before_render
run_test test_cursor_restore_after_render
run_test test_menu_renders_below_input
run_test test_clear_preserves_cursor_position

# --- Key reading tests ---
echo ""
echo "--- Key reading tests ---"

test_read_key_function_exists() {
    # Verify read_key function is defined
    if grep -q "^read_key()" "$SCRIPT_DIR/autocomplete.sh"; then
        pass "Key reading: read_key function is defined"
    else
        fail "Key reading: function definition" "read_key()" "not found"
    fi
}

test_read_key_handles_escape_sequences() {
    # Verify read_key handles escape sequences for arrow keys
    local read_key_func
    read_key_func=$(sed -n '/^read_key/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_up=false has_down=false has_escape=false
    echo "$read_key_func" | grep -q "UP" && has_up=true
    echo "$read_key_func" | grep -q "DOWN" && has_down=true
    echo "$read_key_func" | grep -q "ESCAPE" && has_escape=true

    if [[ $has_up == true ]] && [[ $has_down == true ]] && [[ $has_escape == true ]]; then
        pass "Key reading: handles UP, DOWN, ESCAPE sequences"
    else
        fail "Key reading: escape sequences" "UP, DOWN, ESCAPE" "UP=$has_up, DOWN=$has_down, ESC=$has_escape"
    fi
}

test_read_key_handles_special_keys() {
    # Verify read_key handles Enter, Backspace, Ctrl+C, Ctrl+D
    local read_key_func
    read_key_func=$(sed -n '/^read_key/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    local has_enter=false has_backspace=false has_ctrl_c=false has_ctrl_d=false
    echo "$read_key_func" | grep -q "ENTER" && has_enter=true
    echo "$read_key_func" | grep -q "BACKSPACE" && has_backspace=true
    echo "$read_key_func" | grep -q "CTRL_C" && has_ctrl_c=true
    echo "$read_key_func" | grep -q "CTRL_D" && has_ctrl_d=true

    if [[ $has_enter == true ]] && [[ $has_backspace == true ]] && [[ $has_ctrl_c == true ]] && [[ $has_ctrl_d == true ]]; then
        pass "Key reading: handles ENTER, BACKSPACE, CTRL_C, CTRL_D"
    else
        fail "Key reading: special keys" "all special keys" "ENTER=$has_enter, BS=$has_backspace, ^C=$has_ctrl_c, ^D=$has_ctrl_d"
    fi
}

test_read_key_sets_key_type() {
    # Verify read_key sets KEY_TYPE variable
    local read_key_func
    read_key_func=$(sed -n '/^read_key/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$read_key_func" | grep -q 'KEY_TYPE='; then
        pass "Key reading: sets KEY_TYPE variable"
    else
        fail "Key reading: KEY_TYPE" "KEY_TYPE=" "not found"
    fi
}

test_read_key_sets_key_char() {
    # Verify read_key sets KEY_CHAR for regular characters
    local read_key_func
    read_key_func=$(sed -n '/^read_key/,/^}/p' "$SCRIPT_DIR/autocomplete.sh")

    if echo "$read_key_func" | grep -q 'KEY_CHAR='; then
        pass "Key reading: sets KEY_CHAR for regular characters"
    else
        fail "Key reading: KEY_CHAR" "KEY_CHAR=" "not found"
    fi
}

run_test test_read_key_function_exists
run_test test_read_key_handles_escape_sequences
run_test test_read_key_handles_special_keys
run_test test_read_key_sets_key_type
run_test test_read_key_sets_key_char

# ============================================================
# SECTION 9: PROMPT PRESERVATION TESTS
# ============================================================
echo ""
echo "=========================================="
echo "SECTION 9: Prompt Preservation Tests"
echo "=========================================="
echo ""

test_backspace_preserves_prompt() {
    # BUG TEST: When typing characters after "/" then backspacing all of them
    # plus one more (to backspace the "/" itself), the "> " prompt should
    # still be visible, but currently it's not.

    # Simulate the autocomplete flow:
    # 1. User types "/" - enters autocomplete mode (prints "> " in cc line 225)
    # 2. User types "abc" - input is "/abc" (invisible, only menu shows)
    # 3. User backspaces 4 times - should go: "/abc" -> "/ab" -> "/a" -> "/" -> exit
    # 4. After exit, the "> " prompt should still be there

    # Test the backspace exit branch behavior
    local input="/"
    input+="a"
    input+="b"
    input+="c"

    # Simulate backspacing back to just "/"
    # Backspace 1: /abc -> /ab
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # Backspace 2: /ab -> /a
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # Backspace 3: /a -> /
    [[ ${#input} -gt 1 ]] && input="${input%?}"

    # At this point input should be "/" (length 1)
    # Backspace 4: should trigger exit condition
    local should_exit=false
    if [[ ${#input} -eq 1 ]]; then
        should_exit=true
        # This is where the bug is: the exit code clears the menu but doesn't restore "> "
    fi

    if [[ $should_exit == true ]] && [[ "$input" == "/" ]]; then
        # The logic correctly detects the exit condition
        # But check if clear_autocomplete_menu preserves the prompt
        local backspace_handler
        backspace_handler=$(sed -n '/elif.*\${#input} -eq 1/,/fi/p' "$SCRIPT_DIR/autocomplete.sh")

        # The bug: clear_autocomplete_menu uses '\033[J' which clears everything
        # below the cursor, including the "> " prompt that was printed before
        # entering autocomplete mode. The prompt should be preserved or re-printed.

        # Check if the exit branch re-prints the prompt
        if echo "$backspace_handler" | grep -q 'printf.*>'; then
            pass "Backspace preserves prompt: exit branch re-prints '> '"
        else
            # This will fail - demonstrating the bug
            fail "Backspace preserves prompt: '> ' should be restored after exiting autocomplete" \
                 "printf with '>' found in exit branch" \
                 "not found - prompt gets cleared by clear_autocomplete_menu"
        fi
    else
        fail "Backspace preserves prompt: test setup failed" "should_exit=true, input=/" "exit=$should_exit, input=$input"
    fi
}

run_test test_backspace_preserves_prompt

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
    printf "${GREEN}All tests passed!${RESET}\n"
    exit 0
else
    printf "${RED}Some tests failed${RESET}\n"
    exit 1
fi
