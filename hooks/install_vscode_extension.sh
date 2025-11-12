#!/bin/bash
# Hook that runs on session start
# Automatically installs the latest VS Code extension from marketplace

# Exit silently if code command doesn't exist
if ! command -v code &> /dev/null; then
    exit 0
fi

# Install claude-helper extension in background
(
    code --install-extension YoniChechik.claude-helper --force > /dev/null 2>&1
) &
