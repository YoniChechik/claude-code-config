#!/bin/bash
# Start Claude Code Web UI in background

# Capture original working directory
export CCWEB_ORIGINAL_CWD="$(pwd)"

cd /home/ubuntu/.claude/web-app

# Kill any process using port 3000
PORT_PID=$(sudo lsof -ti:3000 2>/dev/null)
if [ ! -z "$PORT_PID" ]; then
    echo "Port 3000 is occupied by PID: $PORT_PID. Killing it..."
    sudo kill "$PORT_PID" 2>/dev/null || sudo kill -9 "$PORT_PID" 2>/dev/null
    sleep 1
fi

# Kill existing process if running (via dev.pid)
if [ -f dev.pid ]; then
    OLD_PID=$(cat dev.pid)
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Stopping existing dev server (PID: $OLD_PID)..."
        kill "$OLD_PID"
        sleep 1
    fi
    rm -f dev.pid
fi

# Start dev server in background
echo "Starting Claude Code Web UI..."
nohup npm run dev > dev.log 2>&1 &
echo $! > dev.pid

echo "Dev server started (PID: $(cat dev.pid))"
echo "Logs: ~/.claude/web-app/dev.log"
echo "URL: http://localhost:3000"
