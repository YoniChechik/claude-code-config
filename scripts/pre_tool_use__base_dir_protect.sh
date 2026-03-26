#!/bin/bash

# PreToolUse hook: block file edits and git write operations outside _clones directories.
# For Edit/Write/NotebookEdit: checks file_path is inside _clones/ or outside any git repo.
# For Bash: checks if command is a git write operation and cwd is inside _clones/.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow. Outputs JSON with permissionDecision=ask to prompt user.

INPUT=$(cat)

# Skip all protection when working inside ~/.claude config repo
cwd_check=$(echo "$INPUT" | jq -r '.cwd // empty')
file_path_check=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [[ "$cwd_check" == "$HOME/.claude"* ]] || [[ "$file_path_check" == "$HOME/.claude"* ]]; then
    exit 0
fi

tool_name=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$tool_name" = "Bash" ]; then
    # === Git write protection logic ===
    command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    cwd=$(echo "$INPUT" | jq -r '.cwd // empty')

    if [ -z "$command" ]; then
        exit 0
    fi

    GIT_WRITE_PATTERN='^git[[:space:]]+(add|stage|commit|checkout|switch|push|stash|reset|rebase|merge|cherry-pick|mv|rm|clean|branch -[dD])([[:space:]]|$)'

    if echo "$command" | grep -qE "$GIT_WRITE_PATTERN"; then
        if echo "$cwd" | grep -q '_clones/'; then
            exit 0
        fi
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Git write operation outside _clones directory. Use /create-clone for isolated changes."}}
EOF
        exit 0
    fi

    exit 0
else
    # === File edit protection logic (Edit, Write, NotebookEdit) ===
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

    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"File edit outside _clones directory. Use /create-clone for isolated changes."}}
EOF
    exit 0
fi
