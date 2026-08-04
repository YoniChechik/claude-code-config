#!/bin/bash

# PreToolUse hook: block file edits and git write operations outside git worktrees.
# Worktrees live at <repo-root>/.claude/worktrees/<name>/ — Claude Code's native worktree
# convention, used both by the /create-worktree skill and by the harness EnterWorktree tool.
# For Edit/Write/NotebookEdit: checks file_path is inside a worktree or outside any git repo.
# For Bash: checks if command is a git write operation and cwd is inside a worktree.
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

# Strip every span of a shell command that is DATA rather than an executable command,
# so pattern heuristics cannot be tripped by prose (a commit message, a heredoc body).
# Rules, all derived from what the shell would actually execute:
#   - single-quoted spans  -> dropped entirely (never expanded, never executed)
#   - heredoc bodies       -> dropped entirely (fed to stdin as data)
#   - double-quoted spans  -> dropped, EXCEPT nested `$( )` / backtick substitutions,
#                             which the shell DOES execute inside double quotes and
#                             which are therefore kept (recursively)
#   - backticks            -> rewritten to `( )` so the paren heuristic sees them too
#
# ONE exception to "quoted text is data": the quoted argument of `eval` or of
# `bash|sh|zsh|dash -c` IS code — that string is handed straight back to a shell to
# execute. Those spans are kept and scanned as command text. Without this a write
# nested in a substitution, `$(bash -c "git -C <base> commit")`, would sanitize down
# to nothing; the per-segment `eval` / `-c` checks are anchored at segment start and
# never see it, so the span scan is the only thing standing in front of it.
# Every dropped span leaves a space behind, so two fragments can never be glued into
# a token that looks like `git`. Command text outside quotes is preserved verbatim.
#
# Used ONLY by the command-substitution heuristic below. The main per-segment scan
# still runs on the raw command, because it needs the quoted arguments (e.g. the
# target of `cd "/some path"`) to track the effective cwd.
sanitize_shell_text() {
    local s=$1
    local n=${#s}
    local i=0
    local out=""
    # Context stack, top = last word. N top-level, S '..', D "..", P $(..), B `..`,
    # SC/DC = a '..' / ".." span that is an eval / -c argument, i.e. code not data.
    local stack="N"
    local depth="0"      # parallel stack of paren depths, one entry per P context
    local heredocs=""    # FIFO queue of heredoc delimiters awaiting their body
    local c c2 top j q delim ch rest chunk line stripped d
    # A quote opening right after this is a shell-code argument, not a literal.
    local code_arg_lead='(^|[;&|(`]|[[:space:]])(eval|(bash|sh|zsh|dash)[[:space:]]+-c)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$'

    while [ "$i" -lt "$n" ]; do
        top=${stack##* }
        c=${s:i:1}

        # --- inside a single-quoted span: pure literal text ---
        if [ "$top" = "S" ]; then
            if [ "$c" = "'" ]; then
                stack=${stack% *}
                out+=" "
                i=$((i + 1))
                continue
            fi
            # Fast-forward to the closing quote instead of walking char by char.
            rest=${s:i}
            chunk=${rest%%\'*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        # --- inside a double-quoted span: literal EXCEPT command substitutions ---
        if [ "$top" = "D" ]; then
            if [ "$c" = '\' ]; then out+=" "; i=$((i + 2)); continue; fi
            if [ "$c" = '"' ]; then stack=${stack% *}; out+=" "; i=$((i + 1)); continue; fi
            if [ "$c" = '`' ]; then stack="$stack B"; out+="("; i=$((i + 1)); continue; fi
            if [ "$c" = '$' ]; then
                if [ "${s:i+1:1}" = "(" ]; then
                    stack="$stack P"; depth="$depth 1"; out+='$('; i=$((i + 2)); continue
                fi
                i=$((i + 1)); continue
            fi
            # Fast-forward to the next char that could change state.
            rest=${s:i}
            chunk=${rest%%[\`\"\$\\]*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        # --- command context (N top level, P inside $( ), B inside backticks) ---
        if [ "$c" = '\' ]; then
            # Escaped char is literal; keep alphanumerics (so `\g\i\t` still reads as git),
            # blank out anything that could otherwise fake a metacharacter.
            c2=${s:i+1:1}
            case "$c2" in
                [A-Za-z0-9]) out+="$c2" ;;
                *) out+=" " ;;
            esac
            i=$((i + 2)); continue
        fi
        if [ "$c" = "'" ]; then
            if [ "$top" = "SC" ]; then stack=${stack% *}
            elif printf '%s\n' "${out##*$'\n'}" | grep -qE "$code_arg_lead"; then stack="$stack SC"
            else stack="$stack S"; fi
            out+=" "; i=$((i + 1)); continue
        fi
        if [ "$c" = '"' ]; then
            if [ "$top" = "DC" ]; then stack=${stack% *}
            elif printf '%s\n' "${out##*$'\n'}" | grep -qE "$code_arg_lead"; then stack="$stack DC"
            else stack="$stack D"; fi
            out+=" "; i=$((i + 1)); continue
        fi
        if [ "$c" = '`' ]; then
            if [ "$top" = "B" ]; then stack=${stack% *}; out+=")"; else stack="$stack B"; out+="("; fi
            i=$((i + 1)); continue
        fi
        if [ "$c" = '$' ] && [ "${s:i+1:1}" = "(" ]; then
            stack="$stack P"; depth="$depth 1"; out+='$('; i=$((i + 2)); continue
        fi
        if [ "$c" = "(" ]; then
            if [ "$top" = "P" ]; then d=${depth##* }; depth="${depth% *} $((d + 1))"; fi
            out+="("; i=$((i + 1)); continue
        fi
        if [ "$c" = ")" ]; then
            out+=")"
            if [ "$top" = "P" ]; then
                d=${depth##* }; d=$((d - 1))
                if [ "$d" -le 0 ]; then stack=${stack% *}; depth=${depth% *}
                else depth="${depth% *} $d"; fi
            fi
            i=$((i + 1)); continue
        fi
        # Heredoc redirection: queue the delimiter, body is skipped at the next newline.
        # `<<<` is a here-STRING, not a heredoc, so it is excluded.
        if [ "$c" = "<" ] && [ "${s:i+1:1}" = "<" ] && [ "${s:i+2:1}" != "<" ]; then
            j=$((i + 2))
            [ "${s:j:1}" = "-" ] && j=$((j + 1))
            while [ "${s:j:1}" = " " ] || [ "${s:j:1}" = "	" ]; do j=$((j + 1)); done
            q=""
            if [ "${s:j:1}" = "'" ] || [ "${s:j:1}" = '"' ]; then q=${s:j:1}; j=$((j + 1)); fi
            delim=""
            while [ "$j" -lt "$n" ]; do
                ch=${s:j:1}
                if [ -n "$q" ]; then
                    if [ "$ch" = "$q" ]; then j=$((j + 1)); break; fi
                else
                    case "$ch" in [A-Za-z0-9_.-]) ;; *) break ;; esac
                fi
                delim="$delim$ch"; j=$((j + 1))
            done
            [ -n "$delim" ] && heredocs="$heredocs $delim"
            out+=" "; i=$j; continue
        fi
        # Newline in command context: any queued heredoc bodies start here — drop them.
        if [ "$c" = $'\n' ]; then
            out+=$'\n'; i=$((i + 1))
            while [ -n "$heredocs" ]; do
                heredocs=${heredocs# }
                delim=${heredocs%% *}
                if [ "$delim" = "$heredocs" ]; then heredocs=""; else heredocs=${heredocs#* }; fi
                while [ "$i" -lt "$n" ]; do
                    rest=${s:i}
                    line=${rest%%$'\n'*}
                    if [ "$line" = "$rest" ]; then i=$n; else i=$((i + ${#line} + 1)); fi
                    stripped=${line#"${line%%[![:space:]]*}"}
                    stripped=${stripped%"${stripped##*[![:space:]]}"}
                    [ "$stripped" = "$delim" ] && break
                done
            done
            continue
        fi
        out+="$c"; i=$((i + 1))
    done

    printf '%s' "$out"
}

# Does any subshell / command-substitution span in the given (already sanitized)
# text actually invoke a git WRITE *inside* the parens?
#
# Scoped to the span deliberately. A write sitting OUTSIDE the parens —
# `$(git log -1) && git -C /base commit` — is caught by the per-segment scan below,
# which resolves the effective cwd and the -C target properly, so requiring the
# write inside opens no hole. It only stops a read-only span such as
# `MSG=$(git log -1 --format=%B)` from being condemned by the word "commit"
# appearing somewhere else entirely in the command.
#
# Spans are matched with balanced parens, so nested substitutions are covered, and
# an unbalanced `(` is treated as running to end-of-text (conservative).
# Uses the global GIT_WRITE_SUBCMD, set in the Bash branch before this is called.
subshell_span_has_git_write() {
    local s=$1
    local n=${#s}
    local i=0
    local j depth c span
    while [ "$i" -lt "$n" ]; do
        if [ "${s:i:1}" = "(" ]; then
            depth=0
            j=$i
            while [ "$j" -lt "$n" ]; do
                c=${s:j:1}
                if [ "$c" = "(" ]; then
                    depth=$((depth + 1))
                elif [ "$c" = ")" ]; then
                    depth=$((depth - 1))
                    [ "$depth" -le 0 ] && break
                fi
                j=$((j + 1))
            done
            span=${s:i:j - i + 1}
            # Both halves must be inside the span: an actual `git` invocation, and a
            # write subcommand. `)` is part of the trailing boundary because a
            # substitution commonly ends right after it, as in `$(git -C /repo commit)`.
            if printf '%s' "$span" | grep -qE '\<git[[:space:]]' \
                && printf '%s' "$span" | grep -qE "[[:space:]]${GIT_WRITE_SUBCMD}([[:space:]]|\$|\"|'|\))"; then
                return 0
            fi
        fi
        i=$((i + 1))
    done
    return 1
}

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

    has_bypass_shell=0
    has_eval=0
    has_subshell_git=0

    # Pre-split scan: detect subshell groupings `(...)` because tr-splitting on `&|;` would
    # break the parentheses across multiple segments. If an opening `(` is followed (eventually)
    # by a git write subcommand and a closing `)`, treat the whole command as a bypass.
    #
    # This runs on the SANITIZED command, not the raw one. The threat being caught is a git
    # write smuggled through a command substitution, which only executes in command position;
    # the same characters sitting inside a commit message, a single-quoted argument, or a
    # heredoc body are inert prose and must not trip the rule. sanitize_shell_text() keeps
    # exactly the executable part — including `$( )` nested inside double quotes, which the
    # shell really does run — and rewrites backticks to parens so they are caught here too.
    sanitized_command=$(sanitize_shell_text "$command")
    if subshell_span_has_git_write "$sanitized_command"; then
        has_subshell_git=1
    fi

    # Split the compound command on separators (;, &&, ||, |, newlines) into individual segments,
    # then track cd/pushd commands to compute effective_cwd and check if any segment is a git write op.
    # This catches "cd /outside && git commit" even when session cwd is inside a worktree.
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

        # Per-segment bypass detection: a `bash -c "..."` or `eval "..."` segment that
        # contains a git write subcommand anywhere in the segment. These deliberately scan
        # the RAW segment: for these two forms the quoted text IS the command that runs.
        # (Subshell/command-substitution detection is handled by the sanitized pre-split
        # scan above, which sees parens that tr-splitting would have torn apart.)
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
        # Resolve to an absolute path, then require it to be inside a worktree (or CLAUDE_CONFIG_DIR).
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
            # Worktrees live at <repo>/.claude/worktrees/<name>/ — nested inside the base repo
            # but a separate checkout, so they are a legitimate isolated workspace. Covers both
            # feature worktrees from /create-worktree and harness agent worktrees.
            # Require a non-empty <name> component so the container dir itself stays protected.
            if echo "$effective_cwd" | grep -qE '/\.claude/worktrees/[^/]+(/|$)'; then
                exit 0
            fi
            if [[ -n "$CLAUDE_CONFIG_DIR" ]] && [[ "$effective_cwd" == "$CLAUDE_CONFIG_DIR"* ]]; then
                exit 0
            fi
        fi
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DENIED: Git write operation attempted outside a git worktree. Direct writes to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) Run '/create-worktree <feature-description>' — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that worktree."}}
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

    # Inside a git repo: allow modifications inside worktrees, which live at
    # <repo>/.claude/worktrees/<name>/ — nested inside the base repo but a separate checkout,
    # so they are a legitimate isolated workspace. Covers both feature worktrees from
    # /create-worktree and harness agent worktrees. Require a path component AFTER <name>
    # so the worktrees container dir itself stays protected.
    if echo "$file_path" | grep -qE '/\.claude/worktrees/[^/]+/'; then
        exit 0
    fi

    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"DENIED: File edit/write attempted outside a git worktree inside a git repo. Direct edits to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) Run '/create-worktree <feature-description>' — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that worktree. Never edit files directly in the base repo directory."}}
EOF
    exit 0
fi
