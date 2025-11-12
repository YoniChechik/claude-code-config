#!/bin/bash
# Hook that runs on session start
# Automatically installs the latest VS Code extension from marketplace

# Install claude-helper extension in background
(
    code --install-extension YoniChechik.claude-helper --force > /dev/null 2>&1
) &
