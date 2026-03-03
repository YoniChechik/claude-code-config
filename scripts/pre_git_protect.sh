#!/bin/bash

# PreToolUse hook: block git write operations outside _clones directories.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow, Exit 2 = block.

INPUT=$(cat)

command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
cwd=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$command" ]; then
    exit 0
fi

# Check if the command starts with a git write operation.
# Match: git (with optional extra spaces) followed by a write subcommand, then a word boundary.
GIT_WRITE_PATTERN='^git[[:space:]]+(add|stage|commit|checkout|switch|push|stash|reset|rebase|merge|cherry-pick)([[:space:]]|$)'

if echo "$command" | grep -qE "$GIT_WRITE_PATTERN"; then
    # Check if working directory contains _clones/
    if echo "$cwd" | grep -q '_clones/'; then
        exit 0
    fi
    echo "Git operation blocked: git commands (add/stage/commit/checkout/push/stash/reset/rebase/merge/cherry-pick) are not allowed outside _clones directories." >&2
    echo "Use /create-clone to create an isolated clone for your changes." >&2
    exit 2
fi

exit 0
