#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cd "$(dirname "$0")/.."

echo -e "${BLUE}Testing production build with working pane...${NC}"

# Check if production server is already running
if [ -f prod.pid ]; then
    PROD_PID=$(cat prod.pid)
    if ps -p "$PROD_PID" > /dev/null 2>&1; then
        echo -e "${YELLOW}Production server already running (PID: $PROD_PID)${NC}"
        CLEANUP_SERVER=false
    else
        rm -f prod.pid
        CLEANUP_SERVER=true
    fi
else
    CLEANUP_SERVER=true
fi

# Start production server if not running
if [ "$CLEANUP_SERVER" = true ]; then
    echo -e "${BLUE}Building and starting production server...${NC}"
    npm run prod
    sleep 3

    if [ ! -f prod.pid ]; then
        echo -e "${RED}Failed to start production server${NC}"
        exit 1
    fi
fi

# Wait for server to be ready
echo -e "${BLUE}Waiting for server to be ready...${NC}"
MAX_WAIT=30
WAITED=0
while ! curl -s http://localhost:6379 > /dev/null; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo -e "${RED}Server failed to start within ${MAX_WAIT}s${NC}"
        if [ "$CLEANUP_SERVER" = true ]; then
            npm run stop-prod
        fi
        exit 1
    fi
done

echo -e "${GREEN}Server is ready!${NC}"

# Run production build test
echo -e "${BLUE}Running production build E2E test...${NC}"
npx playwright test e2e/production-build.spec.ts

TEST_EXIT_CODE=$?

# Stop server if we started it
if [ "$CLEANUP_SERVER" = true ]; then
    echo -e "${BLUE}Stopping production server...${NC}"
    npm run stop-prod
fi

if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Production build test passed!${NC}"
else
    echo -e "${RED}✗ Production build test failed${NC}"
fi

exit $TEST_EXIT_CODE
