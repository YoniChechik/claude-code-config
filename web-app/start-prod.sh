#!/bin/bash
# Start Claude Code Web UI in production mode

# Capture original working directory
export CCWEB_ORIGINAL_CWD="$(pwd)"

cd /home/ubuntu/.claude/web-app

# Kill any process LISTENING on port 6379 (works for both IPv4 and IPv6)
PORT_PID=$(sudo fuser 6379/tcp 2>/dev/null)
if [ ! -z "$PORT_PID" ]; then
    echo "Stopping server on port 6379..."
    sudo kill $PORT_PID 2>/dev/null || sudo kill -9 $PORT_PID 2>/dev/null
    # Wait longer for graceful shutdown to minimize port unavailability window
    sleep 2
fi

# Kill existing process if running (via prod.pid)
if [ -f prod.pid ]; then
    OLD_PID=$(cat prod.pid)
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Stopping existing production server..."
        kill "$OLD_PID" 2>/dev/null
        sleep 2
    fi
    rm -f prod.pid
fi

# Start production server in background
echo "Starting Claude Code Web UI..."
nohup npm run start > prod.log 2>&1 &
NEW_PID=$!
echo $NEW_PID > prod.pid

# Wait for server to be ready before announcing
sleep 1

echo "Server started (PID: $NEW_PID)"
echo "Logs: ~/.claude/web-app/prod.log"
echo "URL: http://localhost:6379"
