#!/bin/bash
cd "$(dirname "$0")/web-app"
if [ -f dev.pid ]; then
  PID=$(cat dev.pid)
  kill $PID 2>/dev/null && echo "Stopped dev server (PID $PID)" || echo "Process $PID not found"
  rm dev.pid
else
  echo "No dev.pid file found"
fi
