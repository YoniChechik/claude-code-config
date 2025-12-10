#!/bin/bash

# Validate dropdown implementation features

echo "Validating dropdown completion implementation..."
echo ""

errors=0

# Check file exists
if [ ! -f "$HOME/.claude/bin/cc_readline.sh" ]; then
    echo "ERROR: cc_readline.sh not found"
    exit 1
fi

cd "$HOME/.claude"
source bin/cc_readline.sh

# Test 1: Check function exists
if ! declare -f read_with_completion >/dev/null; then
    echo "FAIL: read_with_completion function not found"
    ((errors++))
else
    echo "PASS: read_with_completion function exists"
fi

# Test 2: Check clear_dropdown function
if ! declare -f clear_dropdown >/dev/null; then
    echo "FAIL: clear_dropdown function not found"
    ((errors++))
else
    echo "PASS: clear_dropdown function exists"
fi

# Test 3: Check render_dropdown function
if ! declare -f render_dropdown >/dev/null; then
    echo "FAIL: render_dropdown function not found"
    ((errors++))
else
    echo "PASS: render_dropdown function exists"
fi

# Test 4: Check for reverse video highlighting
if ! grep -q '\\033\[7m' bin/cc_readline.sh; then
    echo "FAIL: Reverse video highlighting not found"
    ((errors++))
else
    echo "PASS: Reverse video highlighting implemented"
fi

# Test 5: Check for up/down arrow handling
if ! grep -q "Up arrow" bin/cc_readline.sh; then
    echo "FAIL: Up arrow handling not found"
    ((errors++))
else
    echo "PASS: Up arrow handling implemented"
fi

if ! grep -q "Down arrow" bin/cc_readline.sh; then
    echo "FAIL: Down arrow handling not found"
    ((errors++))
else
    echo "PASS: Down arrow handling implemented"
fi

# Test 6: Check for dropdown line tracking
if ! grep -q 'dropdown_lines=' bin/cc_readline.sh; then
    echo "FAIL: Dropdown line tracking not found"
    ((errors++))
else
    echo "PASS: Dropdown line tracking implemented"
fi

# Test 7: Check get_matches is available
if ! declare -f get_matches >/dev/null; then
    echo "FAIL: get_matches function not found"
    ((errors++))
else
    echo "PASS: get_matches function available"
fi

# Test 8: Check matches array pattern
test_matches=(cmd1 cmd2 cmd3)
rendered=$(render_dropdown test_matches 1 5)
if [ -z "$rendered" ]; then
    echo "FAIL: render_dropdown didn't return line count"
    ((errors++))
else
    echo "PASS: render_dropdown returns line count"
fi

# Test 9: Check cc integration
if ! grep -q 'source.*cc_readline.sh' bin/cc; then
    echo "FAIL: cc_readline.sh not sourced in main cc script"
    ((errors++))
else
    echo "PASS: cc_readline.sh sourced in main cc script"
fi

if ! grep -q 'read_with_completion' bin/cc; then
    echo "FAIL: read_with_completion not used in main cc script"
    ((errors++))
else
    echo "PASS: read_with_completion used in main cc script"
fi

echo ""
if [ $errors -eq 0 ]; then
    echo "SUCCESS: All validation checks passed!"
    exit 0
else
    echo "FAILED: $errors validation check(s) failed"
    exit 1
fi
