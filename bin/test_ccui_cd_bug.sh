#!/bin/bash

# E2E test for ccui.sh cd bug - tests the ACTUAL ccui.sh code
# This test simulates user interaction with ccui.sh to reproduce the "nothing happens" bug

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================="
echo "CCUI.SH CD Bug E2E Test"
echo "========================================="
echo ""

# Check dependencies
if ! command -v expect >/dev/null 2>&1; then
    echo "Installing expect..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y expect
    else
        echo "Error: expect not available and can't install"
        exit 1
    fi
fi

# Create expect script to interact with ccui.sh
EXPECT_SCRIPT=$(mktemp)
cat > "$EXPECT_SCRIPT" <<'EXPECT_EOF'
#!/usr/bin/expect -f

set timeout 120
set ccui_path [lindex $argv 0]
set log_file [lindex $argv 1]

log_file -a $log_file

spawn bash $ccui_path

# Wait for first prompt
expect {
    timeout {
        puts "TIMEOUT: Waiting for initial prompt"
        exit 1
    }
    -re {[^\r\n]+\r\n}
}

puts "\n=== TEST 1: Send 'cd /tmp' command ==="
send "cd /tmp\r"

# Wait for response
expect {
    timeout {
        puts "TIMEOUT: Waiting for cd /tmp response"
        exit 1
    }
    -re {Changed to /tmp} {
        puts "✓ Got cd /tmp response"
    }
    -re {/tmp} {
        puts "✓ Got cd response (may vary)"
    }
}

# Wait for next prompt (should show /tmp in the path)
expect {
    timeout {
        puts "TIMEOUT: Waiting for prompt after cd"
        exit 1
    }
    -re {/tmp[^\r\n]*\r\n}
}

puts "\n=== TEST 2: Send 'echo hello' command after cd ==="
send "echo hello\r"

# This is where the bug occurs - ccui.sh becomes unresponsive
set timeout 30
expect {
    timeout {
        puts "✗ BUG CONFIRMED: No response to 'echo hello' after cd"
        puts "   ccui.sh is unresponsive!"
        exit 2
    }
    -re {hello} {
        puts "✓ Got echo hello response"
    }
}

# Wait for prompt
expect {
    timeout {
        puts "TIMEOUT: Waiting for prompt after echo"
        exit 1
    }
    -re {[^\r\n]+\r\n}
}

puts "\n=== TEST 3: Send 'pwd' command ==="
send "pwd\r"

expect {
    timeout {
        puts "✗ No response to pwd command"
        exit 2
    }
    -re {/[^\r\n]*} {
        puts "✓ Got pwd response"
    }
}

puts "\n=== All tests passed ==="
send "\x04"
expect eof
exit 0
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"

# Run the test
LOG_FILE=$(mktemp)
echo "Starting ccui.sh test..."
echo "Log file: $LOG_FILE"
echo ""

if "$EXPECT_SCRIPT" "$CLAUDE_DIR/bin/ccui.sh" "$LOG_FILE" 2>&1; then
    echo ""
    echo "========================================="
    echo "✓ ALL TESTS PASSED"
    echo "========================================="
    echo ""
    echo "ccui.sh is working correctly!"
    rm -f "$EXPECT_SCRIPT" "$LOG_FILE"
    exit 0
else
    EXIT_CODE=$?
    echo ""
    echo "========================================="
    echo "✗ TEST FAILED (exit code: $EXIT_CODE)"
    echo "========================================="
    echo ""

    if [ $EXIT_CODE -eq 2 ]; then
        echo "BUG CONFIRMED:"
        echo "- cd /tmp command worked"
        echo "- But subsequent command got NO RESPONSE"
        echo "- ccui.sh became unresponsive after cd"
        echo ""
        echo "This is the 'nothing happens' bug!"
    fi

    echo ""
    echo "Full log:"
    cat "$LOG_FILE"

    rm -f "$EXPECT_SCRIPT" "$LOG_FILE"
    exit 1
fi
