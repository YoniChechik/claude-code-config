#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if production server is running
if [ -f prod.pid ]; then
    PROD_PID=$(cat prod.pid)
    if ps -p "$PROD_PID" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Production server is running (PID: $PROD_PID)${NC}"
        echo -e "${RED}Stop it first with: npm run stop-prod${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}Building test version...${NC}"

# Remove any existing .next symlink or directory
rm -rf .next

# Clean old test build
rm -rf .next-test

# Build fresh for tests
echo -e "${BLUE}Running next build...${NC}"
npm run build

echo -e "${BLUE}Saving test build to .next-test...${NC}"
mv .next .next-test

# Create symlink for test server
ln -sf .next-test .next

echo -e "${GREEN}Test build complete!${NC}"

# Run E2E tests with test config
echo -e "${BLUE}Running E2E tests with concurrency (5 workers)...${NC}"
npx playwright test --config=playwright.test.config.ts "$@"

TEST_EXIT_CODE=$?

if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}Tests failed with exit code $TEST_EXIT_CODE${NC}"
fi

# Clean up symlink after tests
rm -f .next

exit $TEST_EXIT_CODE
