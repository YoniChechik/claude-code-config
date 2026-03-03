#!/bin/bash

# PreToolUse hook: block git write operations outside _clones directories.
# Receives tool input via $CLAUDE_TOOL_INPUT (JSON with "command" field).
# Exit 0 = allow, Exit 2 = block.

command=$(echo "$CLAUDE_TOOL_INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"//p' | sed 's/".*//')

if [ -z "$command" ]; then
    exit 0
fi

# Check if the command starts with a git write operation.
# Match: git (with optional extra spaces) followed by a write subcommand, then a word boundary.
GIT_WRITE_PATTERN='^git[[:space:]]+(add|stage|commit|checkout|switch|push|stash|reset|rebase|merge|cherry-pick)([[:space:]]|$)'

if echo "$command" | grep -qE "$GIT_WRITE_PATTERN"; then
    # Check if working directory contains _clones/
    if echo "$CLAUDE_WORKING_DIRECTORY" | grep -q '_clones/'; then
        exit 0
    fi
    echo "Git operation blocked: git commands (add/stage/commit/checkout/push/stash/reset/rebase/merge/cherry-pick) are not allowed outside _clones directories." >&2
    echo "Use /create-clone to create an isolated clone for your changes." >&2
    exit 2
fi

exit 0
