#!/bin/bash
# Smart build and start for production
# Only rebuilds if source files changed or no build exists

cd /home/ubuntu/.claude/web-app

NEEDS_BUILD=false

# Check if production build exists
if [ ! -d ".next-prod" ]; then
    echo "No production build found, building..."
    NEEDS_BUILD=true
elif [ ! -f ".next-prod/BUILD_ID" ]; then
    echo "Production build incomplete, rebuilding..."
    NEEDS_BUILD=true
else
    # Check if any source files are newer than the build
    CHANGED_FILES=$(find app pages components lib -type f -newer .next-prod/BUILD_ID 2>/dev/null | head -n 1)

    if [ ! -z "$CHANGED_FILES" ]; then
        echo "Source files changed since last build, rebuilding..."
        NEEDS_BUILD=true
    else
        echo "No source changes detected, using existing build"
    fi
fi

# Build if needed (inlined from build-prod.sh)
if [ "$NEEDS_BUILD" = true ]; then
    # Generate version string (try git commit hash first, fallback to date)
    if git rev-parse --short HEAD &>/dev/null; then
        VERSION=$(git rev-parse --short HEAD)
    else
        VERSION=$(date +%Y%m%d-%H%M)
    fi

    echo "Building production version: $VERSION"

    # Write version to .version file
    echo "$VERSION" > /home/ubuntu/.claude/web-app/.version

    # Clean old production build
    rm -rf .next-prod

    npm run build

    if [ $? -eq 0 ]; then
        # Move build to production directory
        mv .next .next-prod
        echo "✓ Production build successful (version: $VERSION)"
        echo "✓ Build saved to .next-prod"
    else
        echo "✗ Production build failed"
        exit 1
    fi
fi

# Start the production server (inlined from start-prod.sh)
# Capture original working directory
export CCWEB_ORIGINAL_CWD="$(pwd)"

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

# Check if production build exists
if [ ! -d ".next-prod" ]; then
    echo "Error: Production build not found at .next-prod"
    exit 1
fi

# Create symlink to production build (exists while server is running)
rm -f .next
ln -sf .next-prod .next

# Start production server in background
echo "Starting Claude Code Web UI..."
echo "Note: .next symlink will point to .next-prod while server is running"
nohup npm run start > prod.log 2>&1 &
NEW_PID=$!
echo $NEW_PID > prod.pid

# Wait for server to be ready before announcing
sleep 1

echo "Server started (PID: $NEW_PID)"
echo "Logs: ~/.claude/web-app/prod.log"
echo "URL: http://localhost:6379"
