#!/bin/bash

# PreToolUse hook: block file edits and git write operations outside _clones directories.
# For Edit/Write/NotebookEdit: checks file_path is inside _clones/ or outside any git repo.
# For Bash: checks if command is a git write operation and cwd is inside _clones/.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 = allow. Outputs JSON with permissionDecision=ask to prompt user.

INPUT=$(cat)

# Derive ~/.claude from the script's own location (robust: no HOME dependency, symlink-safe)
# Script lives at ~/.claude/scripts/pre_tool_use__base_dir_protect.sh
CLAUDE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Skip protection for file_path operations targeting ~/.claude config repo.
file_path_check=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
file_path_check="${file_path_check/#\~/$HOME}"
if [[ -n "$CLAUDE_CONFIG_DIR" ]] && [[ "$file_path_check" == "$CLAUDE_CONFIG_DIR"* ]]; then
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

    # Split the compound command on separators (;, &&, ||, |, newlines) into individual segments,
    # then track cd commands to compute effective_cwd and check if any segment is a git write op.
    # This catches "cd /outside && git commit" even when session cwd is inside _clones/.
    effective_cwd="$cwd"
    has_git_write=0
    while IFS= read -r segment; do
        # Strip leading/trailing whitespace from segment
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [ -z "$segment" ] && continue

        # Track cd commands to follow directory changes
        if echo "$segment" | grep -qE '^\s*cd(\s|$)'; then
            target=$(echo "$segment" | awk '{print $2}')
            if [ -n "$target" ]; then
                target="${target/#\~/$HOME}"
                if [[ "$target" == /* ]]; then
                    effective_cwd="$target"
                else
                    effective_cwd="${effective_cwd}/${target}"
                fi
                effective_cwd=$(cd "$effective_cwd" 2>/dev/null && pwd) || true
            fi
            continue
        fi

        # Check if this segment is a git write operation
        if echo "$segment" | grep -qE "$GIT_WRITE_PATTERN"; then
            has_git_write=1
            break
        fi
    done < <(echo "$command" | tr ';&|' '\n')

    if [ "$has_git_write" = "1" ]; then
        if echo "$effective_cwd" | grep -q '_clones/'; then
            exit 0
        fi
        if [[ -n "$CLAUDE_CONFIG_DIR" ]] && [[ "$effective_cwd" == "$CLAUDE_CONFIG_DIR"* ]]; then
            exit 0
        fi
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DENIED: Git write operation attempted outside a _clones/ directory. Direct writes to the base repo are forbidden. You MUST use the clone+PR workflow: (1) Run '/create-clone <feature-description>' — this creates an isolated git clone under _clones/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that clone. Never commit, push, or stage directly in the base repo directory."}}
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
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DENIED: File edit/write attempted outside a _clones/ directory inside a git repo. Direct edits to the base repo are forbidden. You MUST use the clone+PR workflow: (1) Run '/create-clone <feature-description>' — this creates an isolated git clone under _clones/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that clone. Never edit files directly in the base repo directory."}}
EOF
    exit 0
fi
