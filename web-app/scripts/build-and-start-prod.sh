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

# Build if needed
if [ "$NEEDS_BUILD" = true ]; then
    ./scripts/build-prod.sh
    if [ $? -ne 0 ]; then
        echo "Build failed, aborting"
        exit 1
    fi
fi

# Start the production server
./scripts/start-prod.sh
