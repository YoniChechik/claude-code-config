#!/bin/bash

# PreToolUse hook: block Edit/Write tool calls outside _clones directories (only for files inside git repos).
# Files outside any git repository are always allowed.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow, Exit 2 = block.

INPUT=$(cat)

file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

is_in_git_repo() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -e "$dir/.git" ]; then
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Allow modifications outside git repositories
if ! is_in_git_repo "$(dirname "$file_path")"; then
    exit 0
fi

# Inside a git repo: allow modifications inside _clones directories
if echo "$file_path" | grep -q '_clones/'; then
    exit 0
fi

echo "File modification blocked: Edit/Write operations are not allowed outside _clones directories." >&2
echo "Use /create-clone to create an isolated clone for your changes." >&2
exit 2
