#!/bin/bash
# Regression test for multi-line rendering bug
# Verifies that render_autocomplete_menu doesn't create multiple lines

set -u

GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

# Source the functions from cc
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source <(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/cc")

echo "Testing multi-line rendering bug fix..."
echo ""

# Count how many '\n' are in the render function
newline_count=$(grep -c 'printf.*\\n' <(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/cc") || true)
echo "Checking render_autocomplete_menu function..."
echo "  Newlines found: $newline_count"

# The function should have exactly 1 '\n' (for the initial create_line case)
if [[ $newline_count -eq 1 ]]; then
    printf "${GREEN}PASS${RESET}: render_autocomplete_menu has exactly 1 newline (for create_line=true case)\n"
else
    printf "${RED}FAIL${RESET}: render_autocomplete_menu has $newline_count newlines (expected 1)\n"
    exit 1
fi

# Check that the function has the create_line parameter
if grep -q "create_line" <(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/cc"); then
    printf "${GREEN}PASS${RESET}: render_autocomplete_menu has create_line parameter\n"
else
    printf "${RED}FAIL${RESET}: render_autocomplete_menu missing create_line parameter\n"
    exit 1
fi

# Check that subsequent renders use '\033[B' to move down instead of '\n'
if grep -q '\\033\[B' <(sed -n '/^render_autocomplete_menu/,/^}/p' "$SCRIPT_DIR/cc"); then
    printf "${GREEN}PASS${RESET}: render_autocomplete_menu uses \\033[B to move to existing line\n"
else
    printf "${RED}FAIL${RESET}: render_autocomplete_menu doesn't use \\033[B\n"
    exit 1
fi

# Check that the initial render call passes 'true' for create_line
if grep -q "render_autocomplete_menu filtered_commands.*true" "$SCRIPT_DIR/cc"; then
    printf "${GREEN}PASS${RESET}: Initial render call passes 'true' to create line\n"
else
    printf "${RED}FAIL${RESET}: Initial render call doesn't pass 'true'\n"
    exit 1
fi

# Count subsequent render calls (should NOT have 'true')
subsequent_renders=$(grep -c "render_autocomplete_menu filtered_commands" "$SCRIPT_DIR/cc" || true)
renders_with_true=$(grep -c "render_autocomplete_menu filtered_commands.*true" "$SCRIPT_DIR/cc" || true)

if [[ $subsequent_renders -gt $renders_with_true ]]; then
    printf "${GREEN}PASS${RESET}: Subsequent render calls don't create new lines (${subsequent_renders} total, ${renders_with_true} with 'true')\n"
else
    printf "${RED}FAIL${RESET}: All renders have 'true' - will create multiple lines!\n"
    exit 1
fi

echo ""
echo "Testing wrapped line backspace fix..."
echo ""

# Check that backspace uses '\033[D\033[K' for wrapped line support
if grep -q "printf '\\\\033\[D\\\\033\[K'" "$SCRIPT_DIR/cc"; then
    printf "${GREEN}PASS${RESET}: Backspace handler uses \\033[D\\033[K for wrapped line support\n"
else
    printf "${RED}FAIL${RESET}: Backspace handler doesn't use \\033[D\\033[K\n"
    exit 1
fi

# Check that the old '\b \b' is NOT used in the "/" backspace context (regression check)
if grep -A1 "Backspacing the / itself" "$SCRIPT_DIR/cc" | grep -q "printf '\\\\b \\\\b'"; then
    printf "${RED}FAIL${RESET}: Found old \\b \\b in '/' backspace context (should be \\033[D\\033[K)\n"
    exit 1
else
    printf "${GREEN}PASS${RESET}: '/' backspace context uses correct sequence (not old \\b \\b)\n"
fi

# Check that the backspace fix is at line 241 in the correct context
backspace_line=$(grep -n "printf '\\\\033\[D\\\\033\[K'" "$SCRIPT_DIR/cc" | grep "241:" || true)
if [[ -n "$backspace_line" ]]; then
    printf "${GREEN}PASS${RESET}: Backspace fix is at expected line 241\n"
else
    # Allow for minor line number changes
    actual_line=$(grep -n "printf '\\\\033\[D\\\\033\[K'" "$SCRIPT_DIR/cc" | head -1 | cut -d: -f1)
    if [[ -n "$actual_line" ]]; then
        printf "${GREEN}PASS${RESET}: Backspace fix found at line $actual_line (line numbers may have shifted)\n"
    else
        printf "${RED}FAIL${RESET}: Backspace fix not found\n"
        exit 1
    fi
fi

# Verify the fix is in the right context (backspacing "/" in autocomplete)
if grep -B3 "033\[D" "$SCRIPT_DIR/cc" | grep -q "Backspacing the / itself"; then
    printf "${GREEN}PASS${RESET}: Backspace fix is in correct context (backspacing '/' character)\n"
else
    printf "${RED}FAIL${RESET}: Backspace fix not in expected context\n"
    exit 1
fi

echo ""
printf "${GREEN}All regression tests passed!${RESET}\n"
echo ""
echo "Summary: The fixes ensure that:"
echo "  1. First render creates the menu line with '\\n'"
echo "  2. Subsequent renders move to existing line with '\\033[B'"
echo "  3. No multiple lines accumulate during typing/backspacing"
echo "  4. Backspace uses '\\033[D\\033[K' to properly erase '/' even with wrapped prompts"
echo "  5. Old '\\b \\b' sequence is not present (prevents prompt erasure on wrapped lines)"
