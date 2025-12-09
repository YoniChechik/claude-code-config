#!/bin/bash

# Test slash completion functions from bin/cc

CLAUDE_DIR="$HOME/.claude"
PASS=0
FAIL=0

# Source the completion functions by extracting them
eval "$(sed -n '/^_get_slash_commands/,/^bind -x/p' "$CLAUDE_DIR/bin/cc" | head -n -1)"

# ============================================================
# TEST HELPERS
# ============================================================
test_pass() {
    echo "  ✓ $1"
    ((PASS++))
}

test_fail() {
    echo "  ✗ $1"
    ((FAIL++))
}

assert_eq() {
    if [ "$1" = "$2" ]; then
        test_pass "$3"
    else
        test_fail "$3: expected '$2', got '$1'"
    fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        test_pass "$3"
    else
        test_fail "$3: '$1' does not contain '$2'"
    fi
}

assert_not_empty() {
    if [ -n "$1" ]; then
        test_pass "$2"
    else
        test_fail "$2: output is empty"
    fi
}

# ============================================================
# TESTS
# ============================================================
echo "Testing _get_slash_commands..."

cmds=$(_get_slash_commands)
assert_not_empty "$cmds" "returns commands"
assert_contains "$cmds" "new-feature" "includes new-feature"
assert_contains "$cmds" "finish" "includes finish"

echo ""
echo "Testing _cc_tab_complete with single match..."

# Simulate readline state for "finish" - unique match
READLINE_LINE="/fini"
READLINE_POINT=5
_cc_tab_complete
assert_eq "$READLINE_LINE" "/finish" "completes /fini to /finish"
assert_eq "$READLINE_POINT" "7" "cursor at end"

echo ""
echo "Testing _cc_tab_complete with multiple matches..."

# Test with "new-f" - should match new-feature and new-feature-short
# Note: capture output in temp file to avoid subshell losing READLINE_LINE changes
READLINE_LINE="/new-f"
READLINE_POINT=6
tmpout=$(mktemp)
_cc_tab_complete > "$tmpout" 2>&1
output=$(cat "$tmpout")
rm -f "$tmpout"
# Should show options and set common prefix
assert_contains "$output" "new-feature" "shows new-feature option"
assert_eq "$READLINE_LINE" "/new-feature" "completes to common prefix"

echo ""
echo "Testing _cc_tab_complete with no match..."

READLINE_LINE="/xyz123nonexistent"
READLINE_POINT=18
_cc_tab_complete
assert_eq "$READLINE_LINE" "/xyz123nonexistent" "unchanged on no match"

echo ""
echo "Testing _cc_tab_complete ignores non-slash input..."

READLINE_LINE="hello"
READLINE_POINT=5
_cc_tab_complete
assert_eq "$READLINE_LINE" "hello" "non-slash input unchanged"

echo ""
echo "Testing fuzzy match (substring)..."

READLINE_LINE="/feat"
READLINE_POINT=5
output=$(_cc_tab_complete 2>&1)
assert_contains "$output" "new-feature" "fuzzy matches 'feat' in new-feature"

echo ""
echo "Testing case insensitive match..."

READLINE_LINE="/FINISH"
READLINE_POINT=7
_cc_tab_complete
assert_eq "$READLINE_LINE" "/finish" "case insensitive match works"

echo ""
echo "Testing empty slash (show all)..."

READLINE_LINE="/"
READLINE_POINT=1
tmpout=$(mktemp)
_cc_tab_complete > "$tmpout" 2>&1
output=$(cat "$tmpout")
rm -f "$tmpout"
assert_contains "$output" "finish" "shows finish"
assert_contains "$output" "sync" "shows sync"
assert_contains "$output" "ask" "shows ask"

echo ""
echo "Testing pr- prefix (multiple pr commands)..."

READLINE_LINE="/pr-"
READLINE_POINT=4
tmpout=$(mktemp)
_cc_tab_complete > "$tmpout" 2>&1
output=$(cat "$tmpout")
rm -f "$tmpout"
assert_contains "$output" "pr-create" "shows pr-create"
assert_contains "$output" "pr-comments" "shows pr-comments"
assert_contains "$output" "pr-walkthrough" "shows pr-walkthrough"

echo ""
echo "Testing unique pr command completion..."

READLINE_LINE="/pr-cr"
READLINE_POINT=6
_cc_tab_complete
assert_eq "$READLINE_LINE" "/pr-create" "completes pr-cr to pr-create"

echo ""
echo "Testing completion with trailing space (should not match)..."

READLINE_LINE="/finish "
READLINE_POINT=8
orig_line="$READLINE_LINE"
_cc_tab_complete
assert_eq "$READLINE_LINE" "$orig_line" "trailing space - no completion"

echo ""
echo "Testing partial fuzzy 'clone'..."

READLINE_LINE="/clone"
READLINE_POINT=6
_cc_tab_complete
assert_eq "$READLINE_LINE" "/create-clone" "fuzzy matches clone in create-clone"

echo ""
echo "Testing partial fuzzy 'todo'..."

READLINE_LINE="/todo"
READLINE_POINT=5
_cc_tab_complete
assert_eq "$READLINE_LINE" "/add-todo" "fuzzy matches todo in add-todo"

echo ""
echo "Testing 'cont' matches continue-feature..."

READLINE_LINE="/cont"
READLINE_POINT=5
_cc_tab_complete
assert_eq "$READLINE_LINE" "/continue-feature" "cont completes to continue-feature"

echo ""
echo "Testing single char 'a' (multiple: add-todo, ask, pr-walkthrough)..."

READLINE_LINE="/a"
READLINE_POINT=2
tmpout=$(mktemp)
_cc_tab_complete > "$tmpout" 2>&1
output=$(cat "$tmpout")
rm -f "$tmpout"
assert_contains "$output" "add-todo" "shows add-todo for /a"
assert_contains "$output" "ask" "shows ask for /a"

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
