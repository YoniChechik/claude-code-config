#!/bin/bash

# test_cc_readline.sh - Interactive test for slash completion

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
source "$CLAUDE_DIR/bin/cc_readline.sh"

echo "Testing slash completion (type '/' to start, Ctrl+D to exit)"
echo "Try typing: /ask, /syn, /new"
echo "Use arrow keys to cycle through suggestions"
echo "Press Tab or Enter to accept"
echo ""

while true; do
    input=$(read_with_completion)
    ret=$?
    [ $ret -eq 1 ] && break
    [ $ret -eq 2 ] && continue

    if [ -n "$input" ]; then
        echo "You entered: $input"
    fi
done

echo ""
echo "Done!"
