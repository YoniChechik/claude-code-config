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

test_fuzzy_substring() {
    local matches=$(fuzzy_match "comment")
    echo "$matches" | grep -q "pr-comments" && \
        test_pass "Substring match" || test_fail "Substring match"
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
    [[ $count -ge 5 ]] && test_pass "All commands ($count found)" || test_fail "All commands: got $count"
}

test_score_ordering() {
    local s1=$(fuzzy_score "ask" "ask")
    local s2=$(fuzzy_score "new" "new-feature")
    local s3=$(fuzzy_score "comment" "pr-comments")

    [[ $s1 -eq 0 && $s2 -eq 1 && $s3 -gt 100 ]] && \
        test_pass "Score ordering ($s1 < $s2 < $s3)" || test_fail "Score ordering: $s1 $s2 $s3"
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

test_functions_exist() {
    local missing=()
    for func in get_slash_commands fuzzy_score fuzzy_match save_terminal_state restore_terminal_state read_key render_inline clear_line read_with_autosuggest; do
        declare -f "$func" >/dev/null || missing+=("$func")
    done

    [[ ${#missing[@]} -eq 0 ]] && \
        test_pass "All functions exist" || test_fail "Missing functions: ${missing[*]}"
}

echo "Running autosuggest tests..."
echo ""

test_fuzzy_exact
test_fuzzy_prefix
test_fuzzy_substring
test_fuzzy_case
test_fuzzy_empty
test_fuzzy_all
test_score_ordering
test_score_no_match
test_fuzzy_sorting

test_terminal_state

test_key_tab
test_key_backspace
test_key_enter
test_key_char

test_functions_exist

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
