#!/bin/bash
# Start Claude Code Web UI in background

cd /home/ubuntu/.claude/web-app

# Kill existing process if running
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
