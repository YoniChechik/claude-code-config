#!/bin/bash
# Start Claude Code Web UI in production mode

# Capture original working directory
export CCWEB_ORIGINAL_CWD="$(pwd)"

cd /home/ubuntu/.claude/web-app

# Kill any process LISTENING on port 3000 (works for both IPv4 and IPv6)
PORT_PID=$(sudo fuser 3000/tcp 2>/dev/null)
if [ ! -z "$PORT_PID" ]; then
    echo "Port 3000 is occupied by PID: $PORT_PID. Killing it..."
    sudo kill $PORT_PID 2>/dev/null || sudo kill -9 $PORT_PID 2>/dev/null
    sleep 1
fi

# Kill existing process if running (via prod.pid)
if [ -f prod.pid ]; then
    OLD_PID=$(cat prod.pid)
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "Stopping existing production server (PID: $OLD_PID)..."
        kill "$OLD_PID"
        sleep 1
    fi
    rm -f prod.pid
fi

# Start production server in background
echo "Starting Claude Code Web UI (production mode)..."
nohup npm run start > prod.log 2>&1 &
echo $! > prod.pid

echo "Production server started (PID: $(cat prod.pid))"
echo "Logs: ~/.claude/web-app/prod.log"
echo "URL: http://localhost:3000"
