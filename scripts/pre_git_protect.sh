#!/bin/bash

# PreToolUse hook: block git write operations outside _clones directories.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow. Outputs JSON with permissionDecision=ask to prompt user.

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
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Git write operation outside _clones directory. Use /create-clone for isolated changes."}}
EOF
    exit 0
fi

exit 0
