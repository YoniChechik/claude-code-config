#!/bin/bash
# Hook that runs on session start
# Automatically installs the latest VS Code extension

# Exit silently if not in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    exit 0
fi

# Get the root of the git repository
REPO_ROOT=$(git rev-parse --show-toplevel)

# Check if package.json exists (VS Code extension repo)
if [ ! -f "$REPO_ROOT/package.json" ]; then
    exit 0
fi

# Check if this is the vscode-claude-helper repo
if ! grep -q '"name": "claude-helper"' "$REPO_ROOT/package.json" 2>/dev/null; then
    exit 0
fi

# Run in background to not block session start
(
    cd "$REPO_ROOT" || exit 0

    # Compile TypeScript
    npm run compile > /dev/null 2>&1 || exit 0

    # Package extension
    npx @vscode/vsce package > /dev/null 2>&1 || exit 0

    # Find the latest .vsix file
    VSIX_FILE=$(ls -t claude-helper-*.vsix 2>/dev/null | head -1)

    if [ -n "$VSIX_FILE" ]; then
        # Install extension with --force to override existing
        code --install-extension "$VSIX_FILE" --force > /dev/null 2>&1
    fi
) &
