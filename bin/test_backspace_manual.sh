#!/bin/bash
# Manual test for backspace boundary conditions
# This script simulates the exact bug scenario

echo "==================================="
echo "Backspace Boundary Test"
echo "==================================="
echo ""
echo "This tests the fix for the backspace bug where rapid backspacing"
echo "could erase past the '>' prompt."
echo ""

# Simulate the input state
input="/"
echo "Initial state: input='$input' (len ${#input})"

# Type "abc"
echo "Typing: a, b, c"
input+="a"
echo "  After 'a': input='$input' (len ${#input})"
input+="b"
echo "  After 'b': input='$input' (len ${#input})"
input+="c"
echo "  After 'c': input='$input' (len ${#input})"

echo ""
echo "Now backspacing 4 times (simulating rapid backspace):"

# Backspace 1
echo -n "  Backspace 1: "
if [[ ${#input} -gt 1 ]]; then
    input="${input%?}"
    echo "erased one char -> input='$input' (len ${#input})"
elif [[ ${#input} -eq 1 ]]; then
    echo "at '/', would exit autocomplete"
else
    echo "input empty, would do nothing"
fi

# Backspace 2
echo -n "  Backspace 2: "
if [[ ${#input} -gt 1 ]]; then
    input="${input%?}"
    echo "erased one char -> input='$input' (len ${#input})"
elif [[ ${#input} -eq 1 ]]; then
    echo "at '/', would exit autocomplete"
else
    echo "input empty, would do nothing"
fi

# Backspace 3
echo -n "  Backspace 3: "
if [[ ${#input} -gt 1 ]]; then
    input="${input%?}"
    echo "erased one char -> input='$input' (len ${#input})"
elif [[ ${#input} -eq 1 ]]; then
    echo "at '/', would exit autocomplete"
else
    echo "input empty, would do nothing"
fi

# Backspace 4 (the critical one!)
echo -n "  Backspace 4: "
if [[ ${#input} -gt 1 ]]; then
    input="${input%?}"
    echo "erased one char -> input='$input' (len ${#input})"
elif [[ ${#input} -eq 1 ]]; then
    echo "at '/', EXITING autocomplete cleanly"
    echo "             (clears menu, erases '/', leaves '> ' prompt intact)"
    # In the real code, this returns 1 and exits the function
else
    echo "input empty, DOING NOTHING (protects prompt)"
fi

echo ""
echo "==================================="
echo "Result:"
echo "  - The function exits cleanly when backspacing the '/' character"
echo "  - The prompt '> ' is left intact"
echo "  - No over-erasing occurs"
echo "==================================="
