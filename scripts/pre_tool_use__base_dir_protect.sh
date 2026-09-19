#!/bin/bash

# PreToolUse hook: block file edits and git write operations outside git worktrees.
# Worktrees live at <repo-root>/.claude/worktrees/<name>/ — Claude Code's native worktree
# convention, used both by the /create-worktree skill and by the harness EnterWorktree tool.
# For Edit/Write/NotebookEdit: checks file_path is inside a worktree or outside any git repo.
# For Bash: checks if command is a git write operation and cwd is inside a worktree.
# Receives tool input via stdin as JSON with session_id, cwd, tool_name, tool_input.
# Exit 0 with no output = allow. Otherwise outputs JSON with permissionDecision=deny
# (a refused write) or permissionDecision=ask (the guard could not finish its checks
# and is failing closed).
#
# GIT POLICY: ALLOWLIST, NOT DENYLIST
# ----------------------------------
# This file used to carry a denylist of git write subcommands. A denylist of git
# subcommands is unmaintainable — `tag`, `update-ref`, `notes`, `stash push`,
# `replace`, `filter-branch` and any user-defined alias all write, and every one
# of them was a silent bypass. The model is inverted: a small allowlist names the
# subcommands known to be READ-ONLY (plus `fetch`, which only writes
# remote-tracking refs, and `worktree`, which is the sanctioned escape hatch that
# /create-worktree itself needs). ANYTHING ELSE counts as a write and must run
# inside a worktree. New git subcommands therefore fail safe by default.

# ---------------------------------------------------------------------------
# Output helpers. Defined before anything that can fail, so a fail-closed exit
# is always available.
# ---------------------------------------------------------------------------
emit_decision() { # <deny|ask> <reason>
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
}

DENY_GIT_MSG="DENIED: Git write operation attempted outside a git worktree. Direct writes to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/new-feature <feature-description>' — it creates the worktree and runs the implement-PR-merge pipeline end to end. For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that worktree."
DENY_EDIT_MSG="DENIED: File edit/write attempted outside a git worktree inside a git repo. Direct edits to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/new-feature <feature-description>' — it creates the worktree and runs the implement-PR-merge pipeline end to end. For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that worktree. Never edit files directly in the base repo directory."
INTERNAL_ERROR_MSG="GUARD_INTERNAL_ERROR: the base-dir guard could not complete its checks, so it is failing closed. Ask the user to run this manually or to repair scripts/_shell_command_guard.sh."

INPUT=$(cat)

tool_name=$(echo "$INPUT" | jq -r '.tool_name // empty')

# The shared library is a HARD dependency. Sourcing it silently and carrying on
# would leave every check below matching nothing, which looks exactly like
# "no rule matched" (= allow) to the dispatcher. Fail closed instead.
# shellcheck source=./_shell_command_guard.sh
if ! source "$(dirname "${BASH_SOURCE[0]}")/_shell_command_guard.sh" 2>/dev/null \
    || ! declare -F _strip_leading_wrappers >/dev/null 2>&1 \
    || ! declare -F _resolve_path >/dev/null 2>&1; then
    emit_decision ask "$INTERNAL_ERROR_MSG"
    exit 0
fi

# ---------------------------------------------------------------------------
# git classification
#
# git_classify <normalized-segment> parses ONE git invocation into:
#   GIT_C_TARGET        the first `-C <path>` value, "" when absent
#   GIT_UNSAFE_CONFIG   1 when a `-c alias.…` / `-c include.path=…` /
#                       `--config-env=alias.…` override is present. Such an
#                       override can redefine ANY subcommand name to do
#                       ANYTHING, so the subcommand name stops being evidence
#                       of anything and the invocation is never trusted.
#   GIT_IS_READ         1 when the subcommand is on the read-only allowlist
# Returns 1 when the segment is not a git invocation at all.
# ---------------------------------------------------------------------------

# Subcommands that only read. `fetch` updates remote-tracking refs but never the
# worktree or a local branch, and `worktree` is how a worktree gets created in
# the first place — both are deliberately here.
git_subcommand_is_read() { # <subcommand> <remaining args, ws-collapsed>
    local sub="$1" args="$2" first
    first="${args%%[[:space:]]*}"
    case "$sub" in
        "")
            return 0 ;;
        status|log|diff|diff-tree|diff-index|difftool|show|blame|annotate|describe|\
        rev-parse|rev-list|ls-files|ls-tree|ls-remote|cat-file|show-ref|for-each-ref|\
        merge-base|name-rev|shortlog|grep|whatchanged|count-objects|check-ignore|\
        check-attr|verify-commit|verify-tag|version|help|cherry|range-diff|\
        show-branch|var|fetch|worktree)
            return 0 ;;
        branch)
            # Read only while every argument is a read-ish flag: a positional
            # creates a branch, and -d/-m/-c/-u… mutate one.
            git_branch_args_are_read "$args"
            return $? ;;
        config)
            case " $args " in
                *" --get "*|*" --get="*|*" --get-all "*|*" --get-regexp "*|*" --get-urlmatch "*) return 0 ;;
                *" --list "*|*" -l "*) return 0 ;;
            esac
            case "$first" in
                get|list|--get|--get-all|--get-regexp|--get-urlmatch|--list|-l) return 0 ;;
            esac
            return 1 ;;
        remote)
            case "$first" in
                ""|-v|--verbose|show|get-url) return 0 ;;
            esac
            return 1 ;;
        stash)
            case "$first" in list|show) return 0 ;; esac
            return 1 ;;
        reflog)
            case "$first" in ""|show) return 0 ;; esac
            return 1 ;;
        tag)
            # A bare `git tag` (or `-l`/`-n`) lists; a positional creates a tag.
            case "$first" in
                ""|-l|--list|-n|-n[0-9]*|--contains|--no-contains|--points-at|--merged|--no-merged|--sort|--sort=*|--format|--format=*) return 0 ;;
            esac
            return 1 ;;
        notes)
            case "$first" in list|show) return 0 ;; esac
            return 1 ;;
        bisect)
            case "$first" in log|view) return 0 ;; esac
            return 1 ;;
        submodule)
            case "$first" in status|summary) return 0 ;; esac
            return 1 ;;
    esac
    return 1
}

# `git branch` is read-only only while no argument mutates anything.
git_branch_args_are_read() {
    local args="$1" tok expect_value=0
    while [ -n "$args" ]; do
        tok="${args%%[[:space:]]*}"
        if [ "$tok" = "$args" ]; then args=""; else args="${args#*[[:space:]]}"; fi
        if [ "$expect_value" = "1" ]; then
            expect_value=0
            continue
        fi
        case "$tok" in
            # Read-only flags that consume the NEXT token as their value.
            --contains|--no-contains|--points-at|--merged|--no-merged|--sort|--format|--color)
                expect_value=1 ;;
            # Read-only valueless flags (and their `--flag=value` forms).
            -a|-r|-v|-vv|-q|--all|--remotes|--list|-l|--show-current|--verbose|--quiet|\
            --contains=*|--no-contains=*|--points-at=*|--merged=*|--no-merged=*|--sort=*|--format=*|--color=*|--no-color) ;;
            # Anything else — a write flag (-d/-m/-c/-u/-f/--delete/--move/…) or a
            # positional branch name, which CREATES a branch.
            *) return 1 ;;
        esac
    done
    return 0
}

git_classify() {
    local seg="$1"
    GIT_C_TARGET=""
    GIT_UNSAFE_CONFIG=0
    GIT_IS_READ=0

    local rest tok val sub=""
    case "$seg" in
        git) rest="" ;;
        git[[:space:]]*) rest="${seg#git}" ;;
        *) return 1 ;;
    esac
    rest="${rest#"${rest%%[![:space:]]*}"}"

    # Walk the global-flag region that sits between `git` and its subcommand.
    while [ -n "$rest" ]; do
        tok="${rest%%[[:space:]]*}"
        case "$tok" in
            -C|-c|--git-dir|--work-tree|--exec-path|--namespace|--attr-source|--config-env)
                # Flag plus a separate value token.
                if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
                rest="${rest#"${rest%%[![:space:]]*}"}"
                val="${rest%%[[:space:]]*}"
                if [ "$tok" = "-C" ] && [ -z "$GIT_C_TARGET" ]; then
                    GIT_C_TARGET="$val"
                fi
                if [ "$tok" = "-c" ] || [ "$tok" = "--config-env" ]; then
                    case "$val" in
                        alias.*|include.path=*|includeIf.*|core.pager=*|core.editor=*|core.sshCommand=*|core.hooksPath=*|uploadpack.*|protocol.*)
                            GIT_UNSAFE_CONFIG=1 ;;
                    esac
                fi
                if [ "$val" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
                ;;
            --git-dir=*|--work-tree=*|--exec-path=*|--namespace=*|--attr-source=*|--config-env=*|-c=*)
                case "${tok#*=}" in
                    alias.*|include.path=*|includeIf.*) GIT_UNSAFE_CONFIG=1 ;;
                esac
                if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
                ;;
            -*)
                # Any other global flag (--no-pager, --paginate, -P, --bare, …).
                if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
                ;;
            *)
                sub="$tok"
                if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
                break
                ;;
        esac
        rest="${rest#"${rest%%[![:space:]]*}"}"
    done

    if [ "$GIT_UNSAFE_CONFIG" = "0" ] && git_subcommand_is_read "$sub" "$rest"; then
        GIT_IS_READ=1
    fi
    return 0
}

# Does any subshell / command-substitution span in the given (already sanitized)
# text invoke a git NON-READ subcommand *inside* the parens?
#
# Scoped to the span deliberately. A write sitting OUTSIDE the parens —
# `$(git log -1) && git -C /base commit` — is caught by the per-segment scan below,
# which resolves the effective cwd and the -C target properly, so requiring the
# write inside opens no hole. It only stops a read-only span such as
# `MSG=$(git log -1 --format=%B)` from being condemned by the word "commit"
# appearing somewhere else entirely in the command.
#
# Spans come from _extract_subshell_spans, so nested substitutions are covered.

# Rewrite every `<dir>/git` token in TEXT to a bare `git`, so an absolute-path
# invocation (`/usr/bin/git commit`) is found by the plain `git` token search
# below. _normalize_command_tokens only normalizes a segment's FIRST word; a
# span can hold a git invocation anywhere inside it.
span_basename_git() {
    local s="$1" out="" tok
    # Nothing to rewrite unless a path-prefixed git actually appears. Skipping
    # the token walk here keeps a long span linear instead of quadratic.
    case "$s" in
        */git*) ;;
        *) GUARD_REPLY="$s"; return 0 ;;
    esac
    s="${s#"${s%%[![:space:]]*}"}"
    while [ -n "$s" ]; do
        tok="${s%%[[:space:]]*}"
        if [ "$tok" = "$s" ]; then s=""; else s="${s#*[[:space:]]}"; fi
        s="${s#"${s%%[![:space:]]*}"}"
        case "$tok" in */git) tok="git" ;; esac
        out="${out}${out:+ }${tok}"
    done
    GUARD_REPLY="$out"
}

subshell_span_has_git_write() {
    local span rest
    while IFS= read -r span; do
        _ws_collapse "$span"
        span_basename_git "$GUARD_REPLY"
        rest=" $GUARD_REPLY "
        # Inspect EVERY git invocation in the span, not just the first.
        while :; do
            case "$rest" in
                *" git "*) rest="git ${rest#* git }" ;;
                *" git") rest="git" ;;
                *) break ;;
            esac
            if git_classify "$rest" && [ "$GIT_IS_READ" != "1" ]; then
                return 0
            fi
            # Advance past this `git` token so the loop cannot spin on it.
            if [ "$rest" = "git" ]; then break; fi
            rest=" ${rest#git }"
        done
    done < <(_extract_subshell_spans "$1")
    return 1
}

if [ "$tool_name" = "Bash" ]; then
    # === Git write protection logic ===
    command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    cwd=$(echo "$INPUT" | jq -r '.cwd // empty')

    if [ -z "$command" ]; then
        exit 0
    fi

    # Per-segment bypass patterns: only match when these tokens are the LEAD of a segment,
    # not when they appear inside a heredoc / commit-message body.
    has_bypass_shell=0
    has_eval=0
    has_subshell_git=0
    has_unsafe_config=0

    # Pre-split scan: detect subshell groupings `(...)` because splitting on `&|;` would
    # break the parentheses across multiple segments. If an opening `(` is followed (eventually)
    # by a git write subcommand and a closing `)`, treat the whole command as a bypass.
    #
    # This runs on the SANITIZED command, not the raw one. The threat being caught is a git
    # write smuggled through a command substitution, which only executes in command position;
    # the same characters sitting inside a commit message, a single-quoted argument, or a
    # QUOTED-delimiter heredoc body are inert prose and must not trip the rule.
    # _sanitize_shell_text() keeps exactly the executable part — including `$( )` nested
    # inside double quotes, and the substitutions inside an UNQUOTED-delimiter heredoc body,
    # which the shell really does run — and rewrites backticks to parens so they are caught here.
    _sanitize_shell_text "$command"
    sanitized_command="$GUARD_REPLY"
    if subshell_span_has_git_write "$sanitized_command"; then
        has_subshell_git=1
    fi

    # Split the compound command on separators (;, &&, ||, |, newlines) into individual
    # segments, then track cd/pushd commands to compute effective_cwd and check if any
    # segment is a git write op. This catches "cd /outside && git commit" even when the
    # session cwd is inside a worktree.
    #
    # The split is pure parameter expansion (no `tr` fork) and every per-segment helper
    # returns through GUARD_REPLY (no `$( )` subshell), because this loop runs once per
    # segment and a fork here is what made a long chained command able to time the hook out.
    split_command="${command//;/$'\n'}"
    split_command="${split_command//&/$'\n'}"
    split_command="${split_command//|/$'\n'}"

    effective_cwd="$cwd"
    has_git_write=0
    git_c_target=""
    while IFS= read -r segment; do
        # Strip leading/trailing whitespace from segment
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [ -z "$segment" ] && continue

        # Track cd/pushd commands to follow directory changes.
        case "$segment" in
            cd|pushd|cd[[:space:]]*|pushd[[:space:]]*)
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
                ;;
        esac

        # `normalized_segment` has every `command`/`builtin`/`exec`/`env`/backslash/`VAR=`
        # prefix and every shell grammar keyword (`{`, `then`, `do`, …) peeled off, so
        # `command bash -c "..."`, `exec git commit` and `{ git commit; }` all still hit
        # the checks below.
        _strip_leading_wrappers "$segment"
        normalized_segment="$GUARD_REPLY"
        [ -z "$normalized_segment" ] && continue
        _ws_collapse "$normalized_segment"
        normalized_ws="$GUARD_REPLY"

        # Per-segment bypass detection: a `bash -c "..."` / `eval "..."` segment whose code
        # argument runs a git non-read subcommand. These use the UNWRAPPED code argument
        # (shared library), so trailing argv (`bash -c "…" sentinel`) and combined flags
        # (`bash -lc "…"`) cannot hide it.
        _unwrap_code_arg "$normalized_segment"
        code_arg="$GUARD_REPLY"
        if [ -n "$code_arg" ]; then
            _sanitize_shell_text "($code_arg)"
            if subshell_span_has_git_write "$GUARD_REPLY"; then
                case "$normalized_ws" in
                    eval|eval\ *) has_eval=1 ;;
                    *) has_bypass_shell=1 ;;
                esac
                has_git_write=1
                break
            fi
        fi

        # Is this segment a git invocation, and is its subcommand on the read-only
        # allowlist? Anything not on the allowlist — including an unknown subcommand and
        # any `-c alias.…` override — counts as a write.
        _normalize_command_tokens "$normalized_ws"
        if git_classify "$GUARD_REPLY" && [ "$GIT_IS_READ" != "1" ]; then
            has_git_write=1
            [ "$GIT_UNSAFE_CONFIG" = "1" ] && has_unsafe_config=1
            git_c_target="$GIT_C_TARGET"
            # Early break: "first write wins" — we only need to know one segment triggers.
            break
        fi
    done <<<"$split_command"

    # Promote pre-split subshell-with-git detection (parens span multiple post-split segments).
    if [ "$has_subshell_git" = "1" ]; then
        has_git_write=1
    fi

    if [ "$has_git_write" = "1" ]; then
        # If `git -C <path>` was used, validate that path — it overrides cwd at runtime.
        # Resolve to an absolute path, then require it to be inside a worktree.
        # A `-c alias.…` override is exempt: the alias body can run ANY command, so
        # `-C <worktree>` is no evidence about what it touches. Its -C is ignored and
        # the session's own cwd decides.
        if [ "$has_unsafe_config" = "1" ]; then
            git_c_target=""
        fi
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
        if [ "$has_bypass_shell" != "1" ] && [ "$has_eval" != "1" ] \
            && [ "$has_subshell_git" != "1" ]; then
            # Worktrees live at <repo>/.claude/worktrees/<name>/ — nested inside the base repo
            # but a separate checkout, so they are a legitimate isolated workspace. Covers both
            # feature worktrees from /create-worktree and harness agent worktrees.
            # Require a non-empty <name> component so the container dir itself stays protected.
            case "$effective_cwd" in
                */.claude/worktrees/?*) exit 0 ;;
            esac
        fi
        emit_decision deny "$DENY_GIT_MSG"
        exit 0
    fi

    exit 0
else
    # === File edit protection logic (Edit, Write, NotebookEdit) ===
    file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

    if [ -z "$file_path" ]; then
        exit 0
    fi

    cwd=$(echo "$INPUT" | jq -r '.cwd // empty')
    [ -n "$cwd" ] || cwd="$HOME"

    # CANONICALIZE FIRST. Matching the raw string was a path-traversal bypass:
    # "<repo>/.claude/worktrees/feat/../../../README.md" matches the worktree
    # pattern below character for character while actually pointing at the base
    # repo's README. _resolve_path collapses every `.`/`..`/symlink (and expands
    # a leading ~ / $HOME / $CLAUDE_CONFIG_DIR) before anything is matched.
    resolved_path=$(_resolve_path "$cwd" "$file_path")
    if [ -z "$resolved_path" ]; then
        # Canonicalization itself failed (no python3, unreadable argv). The
        # checks below would be meaningless, so fail closed.
        emit_decision ask "$INTERNAL_ERROR_MSG"
        exit 0
    fi

    is_in_git_repo() {
        local dir="$1"
        while [ "$dir" != "/" ] && [ -n "$dir" ]; do
            if [ -e "$dir/.git" ]; then
                return 0
            fi
            dir="${dir%/*}"
        done
        return 1
    }

    # Allow modifications outside git repositories
    if ! is_in_git_repo "${resolved_path%/*}"; then
        exit 0
    fi

    # Inside a git repo: allow modifications inside worktrees, which live at
    # <repo>/.claude/worktrees/<name>/ — nested inside the base repo but a separate checkout,
    # so they are a legitimate isolated workspace. Covers both feature worktrees from
    # /create-worktree and harness agent worktrees. Require a path component AFTER <name>
    # so the worktrees container dir itself stays protected.
    case "$resolved_path" in
        */.claude/worktrees/*/*) exit 0 ;;
    esac

    emit_decision deny "$DENY_EDIT_MSG"
    exit 0
fi
