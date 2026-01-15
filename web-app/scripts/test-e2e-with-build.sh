#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}Building test version...${NC}"

# Save production build if it exists (not symlink)
if [ -d ".next" ] && [ ! -L ".next" ]; then
    echo -e "${BLUE}Backing up production build...${NC}"
    mv .next .next-prod-backup
elif [ -L ".next" ]; then
    # Remove old symlink
    rm -f .next
fi

# Clean old test build
rm -rf .next-test

# Build fresh for tests
echo -e "${BLUE}Running next build...${NC}"
npm run build

echo -e "${BLUE}Saving test build...${NC}"
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

# Restore production build if it was backed up
if [ -d ".next-prod-backup" ]; then
    echo -e "${BLUE}Restoring production build...${NC}"
    rm -f .next
    mv .next-prod-backup .next
fi

exit $TEST_EXIT_CODE
