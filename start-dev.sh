#!/bin/bash
cd "$(dirname "$0")/web-app"
nohup npm run dev > dev.log 2>&1 &
echo $! > dev.pid
echo "Dev server started with PID $(cat dev.pid)"
echo "Logs: $(pwd)/dev.log"
