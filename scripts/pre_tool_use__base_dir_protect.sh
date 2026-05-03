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

    # Match git write subcommands. Allow:
    #   - optional env-var prefix (e.g. GIT_DIR=x git commit)
    #   - optional absolute path to git binary (e.g. /usr/bin/git commit)
    #   - optional `-C <path>` flag (handled separately for path checking)
    GIT_WRITE_SUBCMD='(add|stage|commit|checkout|switch|push|stash|reset|rebase|merge|cherry-pick|mv|rm|clean|branch[[:space:]]+-[dD])'
    GIT_WRITE_PATTERN="^([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*(/[^[:space:]]+/)?git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)*${GIT_WRITE_SUBCMD}([[:space:]]|$)"

    # Per-segment bypass patterns: only match when these tokens are the LEAD of a segment,
    # not when they appear inside a heredoc / commit-message body.
    BYPASS_SHELL_LEAD='^(bash|sh|zsh|dash)[[:space:]]+-c([[:space:]]|$)'
    EVAL_LEAD='^eval([[:space:]]|$)'
    SUBSHELL_LEAD='^\(.*\<git[[:space:]]+'

    has_bypass_shell=0
    has_eval=0
    has_subshell_git=0

    # Pre-split scan: detect subshell groupings `(...)` because tr-splitting on `&|;` would
    # break the parentheses across multiple segments. If an opening `(` is followed (eventually)
    # by a git write subcommand and a closing `)`, treat the whole command as a bypass.
    if echo "$command" | grep -qE '\([^)]*\<git[[:space:]]+'; then
        # Confirm the inner content actually invokes a write subcommand (not e.g. `(git status)`).
        if echo "$command" | grep -qE "[[:space:]]${GIT_WRITE_SUBCMD}([[:space:]]|\$|\"|')"; then
            has_subshell_git=1
        fi
    fi

    # Split the compound command on separators (;, &&, ||, |, newlines) into individual segments,
    # then track cd/pushd commands to compute effective_cwd and check if any segment is a git write op.
    # This catches "cd /outside && git commit" even when session cwd is inside _clones/.
    effective_cwd="$cwd"
    has_git_write=0
    git_c_target=""
    while IFS= read -r segment; do
        # Strip leading/trailing whitespace from segment
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [ -z "$segment" ] && continue

        # Track cd/pushd commands to follow directory changes.
        # Use [[:space:]] (POSIX) instead of \s (GNU extension) for portability.
        if echo "$segment" | grep -qE '^(cd|pushd)([[:space:]]|$)'; then
            # Drop the leading `cd`/`pushd` token, then trim whitespace.
            target="${segment#cd}"
            target="${target#pushd}"
            target="${target#"${target%%[![:space:]]*}"}"
            target="${target%"${target##*[![:space:]]}"}"

            # Skip cases we cannot resolve safely:
            #  - empty (e.g. bare `cd`)
            #  - `cd -` (switches to OLDPWD, unknown to hook)
            #  - `cd --` (option terminator alone)
            #  - `$VAR` / `"$VAR"` (variable, hook can't expand)
            if [ -z "$target" ] || [ "$target" = "-" ] || [ "$target" = "--" ]; then
                continue
            fi
            case "$target" in
                '$'*|'"$'*|"'\$"*) continue ;;
            esac

            # Strip surrounding matching quotes (single or double).
            case "$target" in
                \"*\") target="${target#\"}"; target="${target%\"}" ;;
                \'*\') target="${target#\'}"; target="${target%\'}" ;;
            esac

            # If after stripping quotes it's a $VAR reference, skip.
            case "$target" in
                '$'*) continue ;;
            esac

            target="${target/#\~/$HOME}"
            if [[ "$target" == /* ]]; then
                candidate="$target"
            else
                candidate="${effective_cwd}/${target}"
            fi
            # Only update effective_cwd if the resolution actually succeeds; otherwise
            # keep the previous value (matches user's mental model: a failed cd at
            # runtime would have left the shell where it was).
            new_cwd=$(cd "$candidate" 2>/dev/null && pwd) && effective_cwd="$new_cwd"
            continue
        fi

        # Per-segment bypass detection: a `bash -c "..."`, `eval "..."`, or `(... git ...)`
        # segment that contains a git write subcommand anywhere in the segment.
        if echo "$segment" | grep -qE "$BYPASS_SHELL_LEAD" && echo "$segment" | grep -qE "[[:space:]]${GIT_WRITE_SUBCMD}([[:space:]]|\$|\"|')"; then
            has_bypass_shell=1
            has_git_write=1
            break
        fi
        if echo "$segment" | grep -qE "$EVAL_LEAD" && echo "$segment" | grep -qE "[[:space:]]${GIT_WRITE_SUBCMD}([[:space:]]|\$|\"|')"; then
            has_eval=1
            has_git_write=1
            break
        fi
        if echo "$segment" | grep -qE "$SUBSHELL_LEAD" && echo "$segment" | grep -qE "[[:space:]]${GIT_WRITE_SUBCMD}([[:space:]]|\$|\"|')"; then
            has_subshell_git=1
            has_git_write=1
            break
        fi

        # Check if this segment is a git write operation (covers env-prefix, absolute-path, and -C variants).
        if echo "$segment" | grep -qE "$GIT_WRITE_PATTERN"; then
            has_git_write=1
            # Capture `-C <path>` only when it is the leading flag of the segment's git invocation
            # (anchored at start, possibly after env-prefix or absolute path). This avoids matching
            # the literal string "git -C ..." inside a commit message body.
            git_c_target=$(echo "$segment" | grep -oE "^([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*(/[^[:space:]]+/)?git[[:space:]]+-C[[:space:]]+[^[:space:]]+" | head -n1 | awk '{
                for (i=1; i<=NF; i++) if ($i == "-C") { print $(i+1); exit }
            }')
            # Early break: "first write wins" — we only need to know one segment triggers the rule.
            break
        fi
    done < <(echo "$command" | tr ';&|' '\n')

    # Promote pre-split subshell-with-git detection (parens span multiple post-split segments).
    if [ "$has_subshell_git" = "1" ]; then
        has_git_write=1
    fi

    if [ "$has_git_write" = "1" ]; then
        # If `git -C <path>` was used, validate that path — it overrides cwd at runtime.
        # Resolve to an absolute path, then require it to be inside _clones/ (or CLAUDE_CONFIG_DIR).
        if [ -n "$git_c_target" ]; then
            git_c_target="${git_c_target/#\~/$HOME}"
            if [[ "$git_c_target" != /* ]]; then
                git_c_target="${effective_cwd}/${git_c_target}"
            fi
            git_c_resolved=$(cd "$git_c_target" 2>/dev/null && pwd)
            if [ -z "$git_c_resolved" ]; then
                # Can't resolve -> conservative deny by leaving effective_cwd unchanged but failing the allow checks.
                effective_cwd="/__unresolved_git_C__"
            else
                effective_cwd="$git_c_resolved"
            fi
        fi
        if [ "$has_bypass_shell" != "1" ] && [ "$has_eval" != "1" ] && [ "$has_subshell_git" != "1" ]; then
            if echo "$effective_cwd" | grep -q '_clones/'; then
                exit 0
            fi
            if [[ -n "$CLAUDE_CONFIG_DIR" ]] && [[ "$effective_cwd" == "$CLAUDE_CONFIG_DIR"* ]]; then
                exit 0
            fi
        fi
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DENIED: Git write operation attempted outside a _clones/ directory. Direct writes to the base repo are forbidden. You MUST use the clone+PR workflow: (1) Run '/create-clone <feature-description>' — this creates an isolated git clone under _clones/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that clone."}}
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
