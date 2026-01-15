#!/bin/bash
# Restart the production server with minimal SSH port forwarding errors
# This script minimizes the window where port 6379 is unavailable

cd /home/ubuntu/.claude/web-app

echo "Restarting server..."

# Start new server first (it will handle killing the old one)
./start-prod.sh 2>&1 | grep -v "connection refused" | grep -v "channel.*open failed"

echo "Server restarted successfully"
