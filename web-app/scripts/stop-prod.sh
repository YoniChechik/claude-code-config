#!/bin/bash
# Stop Claude Code Web UI production server

cd /home/ubuntu/.claude/web-app

# Kill the production server using prod.pid
if [ -f prod.pid ]; then
    PID=$(cat prod.pid)
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "Stopping production server (PID: $PID)..."
        kill "$PID" 2>/dev/null
        sleep 2

        # Force kill if still running
        if ps -p "$PID" > /dev/null 2>&1; then
            echo "Force stopping server..."
            kill -9 "$PID" 2>/dev/null
        fi

        echo "Server stopped"
    else
        echo "No running server found for PID $PID"
    fi

    # Clean up prod.pid file
    rm -f prod.pid
else
    echo "No prod.pid file found"
fi

# Remove .next symlink if it points to .next-prod
if [ -L .next ]; then
    TARGET=$(readlink .next)
    if [ "$TARGET" = ".next-prod" ]; then
        echo "Removing .next symlink"
        rm -f .next
    fi
fi

echo "Production server cleanup complete"
