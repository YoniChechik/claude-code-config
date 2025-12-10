#!/bin/bash

# Test dropdown completion

cd "$HOME/.claude"
source bin/cc_readline.sh

echo "Type '/' to test dropdown completion (use arrows, Tab/Enter to accept, Escape to cancel)"
echo "Press Ctrl+D to exit"
echo ""

result=$(read_with_completion)
ret=$?

if [ $ret -eq 0 ]; then
    echo "Result: $result"
else
    echo "Cancelled (code $ret)"
fi
