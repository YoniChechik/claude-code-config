#!/bin/bash

# PreToolUse hook: block file edits and git write operations outside _clones directories.
# For Edit/Write/NotebookEdit: checks file_path is inside _clones/ or outside any git repo.
# For Bash: checks if command is a git write operation and cwd is inside _clones/.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow. Outputs JSON with permissionDecision=ask to prompt user.
#
# NOTE: Claude Code has a hardcoded built-in block on Edit/Write tools for ~/.claude/
# that fires AFTER hooks, overriding any permissionDecision:"allow" from PreToolUse.
# The ~/.claude exemption below is therefore redundant for Edit/Write (Claude Code blocks
# those anyway), but is still needed for Bash tool git write operations in ~/.claude.
# Refs: https://docs.anthropic.com/en/docs/claude-code/settings
#       anthropics/claude-code#37765, #35718, #38806

INPUT=$(cat)

# Derive ~/.claude from the script's own location (robust: no HOME dependency, symlink-safe)
# Script lives at ~/.claude/scripts/pre_tool_use__base_dir_protect.sh
CLAUDE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Skip git-write protection for ~/.claude config repo.
# NOTE: For Edit/Write tools, Claude Code's built-in ~/.claude block overrides this anyway.
# This exemption only has real effect for Bash tool git operations inside ~/.claude.
cwd_check=$(echo "$INPUT" | jq -r '.cwd // empty')
file_path_check=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
# Expand leading tilde to actual home dir so paths like ~/.claude/... match the resolved CLAUDE_CONFIG_DIR
cwd_check="${cwd_check/#\~/$HOME}"
file_path_check="${file_path_check/#\~/$HOME}"
if [[ -n "$CLAUDE_CONFIG_DIR" ]] && { [[ "$cwd_check" == "$CLAUDE_CONFIG_DIR"* ]] || [[ "$file_path_check" == "$CLAUDE_CONFIG_DIR"* ]]; }; then
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
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
    file_path="${file_path/#\~/$HOME}"

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
