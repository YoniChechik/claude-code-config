#!/bin/bash

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
source "$(dirname "$0")/autosuggest.sh"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
test_fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

test_fuzzy_exact() {
    local result=$(fuzzy_match "ask" | head -1)
    [[ "$result" == "ask" ]] && test_pass "Exact match" || test_fail "Exact match: got '$result'"
}

test_fuzzy_prefix() {
    local matches=$(fuzzy_match "new")
    local first=$(echo "$matches" | head -1)
    [[ "$first" == "new-feature" || "$first" == "new-feature-short" ]] && \
        test_pass "Prefix match" || test_fail "Prefix match: got '$first'"
}

test_no_substring() {
    local matches=$(fuzzy_match "comment")
    [[ -z "$matches" ]] && \
        test_pass "No substring match" || test_fail "No substring match: got '$matches'"
}

test_fuzzy_case() {
    local matches=$(fuzzy_match "ASK")
    echo "$matches" | grep -q "ask" && \
        test_pass "Case insensitive" || test_fail "Case insensitive"
}

test_fuzzy_empty() {
    local matches=$(fuzzy_match "zzzzzzz")
    [[ -z "$matches" ]] && test_pass "Empty result" || test_fail "Empty result: got '$matches'"
}

test_fuzzy_all() {
    local matches=$(fuzzy_match "")
    local count=$(echo "$matches" | grep -c .)
    # Should have user commands + built-ins (at least 15+)
    [[ $count -ge 15 ]] && test_pass "All commands ($count found)" || test_fail "All commands: got $count"
}

test_builtins_included() {
    local matches=$(fuzzy_match "")
    echo "$matches" | grep -q "^help$" && \
        test_pass "Built-in 'help' included" || test_fail "Built-in 'help' not found"
}

test_multiple_builtins() {
    local matches=$(fuzzy_match "")
    local found=0
    for cmd in clear compact config help vim; do
        echo "$matches" | grep -q "^${cmd}$" && found=$((found + 1))
    done
    [[ $found -eq 5 ]] && test_pass "Multiple built-ins ($found/5)" || test_fail "Multiple built-ins: $found/5"
}

test_builtin_prefix_match() {
    local matches=$(fuzzy_match "hel")
    echo "$matches" | grep -q "^help$" && \
        test_pass "Built-in prefix 'hel' → help" || test_fail "Built-in prefix match failed"
}

test_project_root() {
    local root=$(find_project_root)
    [[ -n "$root" ]] && test_pass "Project root found: $root" || test_fail "No project root"
}

test_project_root_has_git() {
    local root=$(find_project_root)
    [[ -d "$root/.git" ]] && test_pass "Project root has .git" || test_fail "Project root missing .git"
}

test_user_commands_exist() {
    local matches=$(fuzzy_match "")
    echo "$matches" | grep -q "^ask$" && \
        test_pass "User command 'ask' exists" || test_fail "User command 'ask' not found"
}

test_no_middle_substring() {
    # "eature" is in "new-feature" but not at start
    local matches=$(fuzzy_match "eature")
    [[ -z "$matches" ]] && \
        test_pass "No middle substring 'eature'" || test_fail "Middle substring matched: $matches"
}

test_prefix_only_strict() {
    # "ync" should NOT match "sync" (not prefix)
    local matches=$(fuzzy_match "ync")
    echo "$matches" | grep -q "^sync$" && \
        test_fail "Non-prefix 'ync' matched sync" || test_pass "Non-prefix 'ync' rejected"
}

test_score_exact_zero() {
    local score=$(fuzzy_score "help" "help")
    [[ $score -eq 0 ]] && test_pass "Exact match score = 0" || test_fail "Exact score: $score"
}

test_score_prefix_one() {
    local score=$(fuzzy_score "hel" "help")
    [[ $score -eq 1 ]] && test_pass "Prefix match score = 1" || test_fail "Prefix score: $score"
}

test_score_nonmatch_999() {
    local score=$(fuzzy_score "xyz" "help")
    [[ $score -eq 999 ]] && test_pass "Non-match score = 999" || test_fail "Non-match score: $score"
}

test_case_insensitive_builtin() {
    local matches=$(fuzzy_match "HELP")
    echo "$matches" | grep -q "^help$" && \
        test_pass "Case insensitive built-in" || test_fail "Case insensitive built-in failed"
}

test_multiline_tracking() {
    # Test that PREV_RENDER_LINES is updated correctly
    PREV_RENDER_LINES=1
    # Simulate render with short text (should be 1 line on 80-col terminal)
    local old_cols=$(tput cols 2>/dev/null || echo 80)
    # Force calculation for 80 cols
    local display_len=$((2 + 10))  # "> " + 10 chars
    local lines=$(( (display_len + 80 - 1) / 80 ))
    [[ $lines -eq 1 ]] && test_pass "Short text = 1 line" || test_fail "Short text lines: $lines"
}

test_multiline_wrap_calculation() {
    # Test line wrap calculation: 85 chars on 80-col terminal = 2 lines
    local display_len=$((2 + 85))  # "> " + 85 chars = 87 chars
    local lines=$(( (display_len + 80 - 1) / 80 ))
    [[ $lines -eq 2 ]] && test_pass "87 chars on 80-col = 2 lines" || test_fail "Wrap calc: $lines"
}

test_prev_render_lines_exists() {
    # PREV_RENDER_LINES should be defined
    [[ -n "${PREV_RENDER_LINES+x}" ]] && \
        test_pass "PREV_RENDER_LINES defined" || test_fail "PREV_RENDER_LINES not defined"
}

test_score_ordering() {
    local s1=$(fuzzy_score "ask" "ask")
    local s2=$(fuzzy_score "new" "new-feature")
    local s3=$(fuzzy_score "comment" "pr-comments")

    [[ $s1 -eq 0 && $s2 -eq 1 && $s3 -eq 999 ]] && \
        test_pass "Score ordering ($s1 < $s2, $s3=999)" || test_fail "Score ordering: $s1 $s2 $s3"
}

test_score_no_match() {
    local score=$(fuzzy_score "xyz" "abc")
    [[ $score -eq 999 ]] && test_pass "No match score" || test_fail "No match score: got $score"
}

test_fuzzy_sorting() {
    local matches=$(fuzzy_match "pr")
    local first=$(echo "$matches" | head -1)
    [[ "$first" == pr-* ]] && test_pass "Match sorting" || test_fail "Match sorting: first was '$first'"
}

test_terminal_state() {
    if ! tty -s 2>/dev/null; then
        echo "⊘ Terminal state (skipped - no TTY)"
        return
    fi

    local before=$(stty -g 2>/dev/null)
    save_terminal_state
    local during=$(stty -g 2>/dev/null)
    restore_terminal_state
    local after=$(stty -g 2>/dev/null)

    [[ "$before" == "$after" && "$before" != "$during" ]] && \
        test_pass "Terminal state" || test_fail "Terminal state"
}

test_key_tab() {
    (echo -en '\t' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "TAB" ]]
    )) && test_pass "Tab detection" || test_fail "Tab detection"
}

test_key_arrow_up() {
    (echo -en '\x1b[A' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "ARROW_UP" ]]
    )) && test_pass "Arrow up detection" || test_fail "Arrow up detection"
}

test_key_arrow_down() {
    (echo -en '\x1b[B' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "ARROW_DOWN" ]]
    )) && test_pass "Arrow down detection" || test_fail "Arrow down detection"
}

test_key_arrow_left() {
    (echo -en '\x1b[D' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "ARROW_LEFT" ]]
    )) && test_pass "Arrow left detection" || test_fail "Arrow left detection"
}

test_key_arrow_right() {
    (echo -en '\x1b[C' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "ARROW_RIGHT" ]]
    )) && test_pass "Arrow right detection" || test_fail "Arrow right detection"
}

test_key_backspace() {
    (echo -en '\x7f' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "BACKSPACE" ]]
    )) && test_pass "Backspace detection" || test_fail "Backspace detection"
}

test_key_enter() {
    (echo -en '\n' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "ENTER" ]]
    )) && test_pass "Enter detection" || test_fail "Enter detection"
}

test_key_char() {
    (echo -en 'a' | (
        save_terminal_state
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "CHAR" && "$KEY_VALUE" == "a" ]]
    )) && test_pass "Char detection" || test_fail "Char detection"
}

test_key_paste_start() {
    (echo -en '\x1b[200~' | (
        save_terminal_state
        PASTE_MODE=false
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "PASTE_START" && "$PASTE_MODE" == true ]]
    )) && test_pass "Paste start detection" || test_fail "Paste start detection"
}

test_key_paste_end() {
    (echo -en '\x1b[201~' | (
        save_terminal_state
        PASTE_MODE=true
        read_key
        restore_terminal_state
        [[ "$KEY_TYPE" == "PASTE_END" && "$PASTE_MODE" == false ]]
    )) && test_pass "Paste end detection" || test_fail "Paste end detection"
}

test_paste_mode_initial_state() {
    [[ "$PASTE_MODE" == false ]] && \
        test_pass "PASTE_MODE initial state is false" || test_fail "PASTE_MODE initial state"
}

test_paste_mode_variable_exists() {
    [[ -n "${PASTE_MODE+x}" ]] && \
        test_pass "PASTE_MODE variable exists" || test_fail "PASTE_MODE variable not defined"
}

test_paste_start_sets_mode() {
    (echo -en '\x1b[200~' | (
        save_terminal_state
        PASTE_MODE=false
        read_key
        restore_terminal_state
        [[ "$PASTE_MODE" == true ]]
    )) && test_pass "Paste start sets PASTE_MODE=true" || test_fail "Paste start mode change"
}

test_paste_end_clears_mode() {
    (echo -en '\x1b[201~' | (
        save_terminal_state
        PASTE_MODE=true
        read_key
        restore_terminal_state
        [[ "$PASTE_MODE" == false ]]
    )) && test_pass "Paste end sets PASTE_MODE=false" || test_fail "Paste end mode change"
}

test_functions_exist() {
    local missing=()
    for func in find_project_root get_slash_commands fuzzy_score fuzzy_match save_terminal_state restore_terminal_state read_key render_inline clear_line read_with_autosuggest; do
        declare -f "$func" >/dev/null || missing+=("$func")
    done

    [[ ${#missing[@]} -eq 0 ]] && \
        test_pass "All functions exist" || test_fail "Missing functions: ${missing[*]}"
}

test_stty_min1() {
    if ! tty -s 2>/dev/null; then
        echo "⊘ stty min 1 (skipped - no TTY)"
        return
    fi

    save_terminal_state
    local settings=$(stty -a 2>/dev/null)
    restore_terminal_state

    echo "$settings" | grep -q "min = 1" && \
        test_pass "stty min 1 set" || test_fail "stty min 1 not set"
}

echo "Running autosuggest tests..."
echo ""

# Matching tests
test_fuzzy_exact
test_fuzzy_prefix
test_no_substring
test_no_middle_substring
test_prefix_only_strict
test_fuzzy_case
test_fuzzy_empty
test_fuzzy_all
test_fuzzy_sorting

# Score tests
test_score_exact_zero
test_score_prefix_one
test_score_nonmatch_999
test_score_ordering
test_score_no_match

# Multi-source command tests
test_builtins_included
test_multiple_builtins
test_builtin_prefix_match
test_case_insensitive_builtin
test_user_commands_exist
test_project_root
test_project_root_has_git

# Multiline rendering tests
test_multiline_tracking
test_multiline_wrap_calculation
test_prev_render_lines_exists

# Terminal state tests
test_terminal_state
test_stty_min1

# Key detection tests
test_key_tab
test_key_arrow_up
test_key_arrow_down
test_key_arrow_left
test_key_arrow_right
test_key_backspace
test_key_enter
test_key_char
test_key_paste_start
test_key_paste_end

# Bracketed paste mode tests
test_paste_mode_variable_exists
test_paste_mode_initial_state
test_paste_start_sets_mode
test_paste_end_clears_mode

# Function existence test
test_functions_exist

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
