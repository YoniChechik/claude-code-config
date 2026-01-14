#!/bin/bash

# Generate version string (try git commit hash first, fallback to date)
if git rev-parse --short HEAD &>/dev/null; then
    VERSION=$(git rev-parse --short HEAD)
else
    VERSION=$(date +%Y%m%d-%H%M)
fi

echo "Building production version: $VERSION"

# Write version to .version file
echo "$VERSION" > /home/ubuntu/.claude/web-app/.version

# Run build
cd /home/ubuntu/.claude/web-app
npm run build

if [ $? -eq 0 ]; then
    echo "✓ Production build successful (version: $VERSION)"
else
    echo "✗ Production build failed"
    exit 1
fi
