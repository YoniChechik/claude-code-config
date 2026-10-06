#!/bin/bash

emit_decision() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
}

DENY_GIT_MSG="DENIED: Git write operation attempted outside a git worktree. Direct writes to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that worktree."
DENY_EDIT_MSG="DENIED: File edit/write attempted outside a git worktree inside a git repo. Direct edits to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that worktree. Never edit files directly in the base repo directory."
INTERNAL_ERROR_MSG="GUARD_INTERNAL_ERROR: the base-dir guard could not complete its checks, so it is failing closed. Ask the user to run this manually or to repair scripts/_shell_command_guard.sh."

INPUT=$(cat)

tool_name=$(echo "$INPUT" | jq -r '.tool_name // empty')

# shellcheck source=./_shell_command_guard.sh
if ! source "$(dirname "${BASH_SOURCE[0]}")/_shell_command_guard.sh" 2>/dev/null \
    || ! declare -F _strip_leading_wrappers >/dev/null 2>&1 \
    || ! declare -F _resolve_path >/dev/null 2>&1; then
    emit_decision ask "$INTERNAL_ERROR_MSG"
    exit 0
fi

git_subcommand_is_read() {
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
            if git_branch_args_are_read "$args"; then
                return 0
            fi
            git_branch_delete_is_merged "$args"
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
        checkout)
            case "$args" in
                "-f main"|"-f master") return 0 ;;
            esac
            return 1 ;;
        reset)
            case "$args" in
                "--hard origin/main"|"--hard origin/master") return 0 ;;
            esac
            return 1 ;;
        clean)
            case "$args" in
                -fd|-df|-fdx|-fxd|-dfx|-dxf|-xfd|-xdf) return 0 ;;
            esac
            return 1 ;;
    esac
    return 1
}

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
            --contains|--no-contains|--points-at|--merged|--no-merged|--sort|--format|--color)
                expect_value=1 ;;
            -a|-r|-v|-vv|-q|--all|--remotes|--list|-l|--show-current|--verbose|--quiet|\
            --contains=*|--no-contains=*|--points-at=*|--merged=*|--no-merged=*|--sort=*|--format=*|--color=*|--no-color) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

git_branch_delete_is_merged() {
    local args="$1" tok name="" saw_delete=0 repo_dir head_ref short ref

    while [ -n "$args" ]; do
        tok="${args%%[[:space:]]*}"
        if [ "$tok" = "$args" ]; then args=""; else args="${args#*[[:space:]]}"; fi
        args="${args#"${args%%[![:space:]]*}"}"
        case "$tok" in
            -d|-D|--delete) saw_delete=1 ;;
            -f|--force|-q|--quiet) ;;
            -*|*'*'*|*'?'*|*'['*|*'~'*|*'^'*|*':'*|*'\'*|*'..'*|*'$'*|*'"'*|*"'"*) return 1 ;;
            *)
                [ -n "$name" ] && return 1
                name="$tok" ;;
        esac
    done
    [ "$saw_delete" = "1" ] && [ -n "$name" ] || return 1

    repo_dir="${GIT_C_TARGET:-}"
    repo_dir="${repo_dir/#\~/$HOME}"
    if [ -z "$repo_dir" ]; then
        repo_dir="${effective_cwd:-$cwd}"
    elif [ "${repo_dir#/}" = "$repo_dir" ]; then
        repo_dir="${effective_cwd:-$cwd}/$repo_dir"
    fi
    [ -n "$repo_dir" ] && [ -d "$repo_dir" ] || return 1

    git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1 || return 1

    head_ref=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    short="${head_ref#origin/}"

    case "$name" in
        main|master) return 1 ;;
    esac
    [ -n "$short" ] && [ "$name" = "$short" ] && return 1

    for ref in "refs/remotes/origin/$short" "refs/heads/$short" \
        refs/remotes/origin/main refs/heads/main \
        refs/remotes/origin/master refs/heads/master; do
        [ "$ref" = "refs/remotes/origin/" ] && continue
        [ "$ref" = "refs/heads/" ] && continue
        [ "$ref" = "refs/heads/$name" ] && continue
        git -C "$repo_dir" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
        if git -C "$repo_dir" merge-base --is-ancestor "refs/heads/$name" "$ref" 2>/dev/null; then
            return 0
        fi
    done
    return 1
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

    while [ -n "$rest" ]; do
        tok="${rest%%[[:space:]]*}"
        case "$tok" in
            -C|-c|--git-dir|--work-tree|--exec-path|--namespace|--attr-source|--config-env)
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

span_basename_git() {
    local s="$1" out="" tok
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
        while :; do
            case "$rest" in
                *" git "*) rest="git ${rest#* git }" ;;
                *" git") rest="git" ;;
                *) break ;;
            esac
            if git_classify "$rest" && [ "$GIT_IS_READ" != "1" ]; then
                return 0
            fi
            if [ "$rest" = "git" ]; then break; fi
            rest=" ${rest#git }"
        done
    done < <(_extract_subshell_spans "$1")
    return 1
}

if [ "$tool_name" = "Bash" ]; then
    command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    cwd=$(echo "$INPUT" | jq -r '.cwd // empty')

    if [ -z "$command" ]; then
        exit 0
    fi

    has_bypass_shell=0
    has_eval=0
    has_subshell_git=0
    has_unsafe_config=0

    _sanitize_shell_text "$command"
    sanitized_command="$GUARD_REPLY"
    if subshell_span_has_git_write "$sanitized_command"; then
        has_subshell_git=1
    fi

    split_command="${command//;/$'\n'}"
    split_command="${split_command//&/$'\n'}"
    split_command="${split_command//|/$'\n'}"

    effective_cwd="$cwd"
    has_git_write=0
    git_c_target=""
    while IFS= read -r segment; do
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [ -z "$segment" ] && continue

        case "$segment" in
            cd|pushd|cd[[:space:]]*|pushd[[:space:]]*)
                target="${segment#cd}"
                target="${target#pushd}"
                target="${target#"${target%%[![:space:]]*}"}"
                target="${target%"${target##*[![:space:]]}"}"

                if [ -z "$target" ] || [ "$target" = "-" ] || [ "$target" = "--" ]; then
                    continue
                fi
                case "$target" in
                    '$'*|'"$'*|"'\$"*) continue ;;
                esac

                case "$target" in
                    \"*\") target="${target#\"}"; target="${target%\"}" ;;
                    \'*\') target="${target#\'}"; target="${target%\'}" ;;
                esac

                case "$target" in
                    '$'*) continue ;;
                esac

                target="${target/#\~/$HOME}"
                if [[ "$target" == /* ]]; then
                    candidate="$target"
                else
                    candidate="${effective_cwd}/${target}"
                fi
                new_cwd=$(cd "$candidate" 2>/dev/null && pwd) && effective_cwd="$new_cwd"
                continue
                ;;
        esac

        _strip_leading_wrappers "$segment"
        normalized_segment="$GUARD_REPLY"
        [ -z "$normalized_segment" ] && continue
        _ws_collapse "$normalized_segment"
        normalized_ws="$GUARD_REPLY"

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

        _normalize_command_tokens "$normalized_ws"
        if git_classify "$GUARD_REPLY" && [ "$GIT_IS_READ" != "1" ]; then
            has_git_write=1
            [ "$GIT_UNSAFE_CONFIG" = "1" ] && has_unsafe_config=1
            git_c_target="$GIT_C_TARGET"
            break
        fi
    done < <(printf '%s\n' "$split_command")

    if [ "$has_subshell_git" = "1" ]; then
        has_git_write=1
    fi

    if [ "$has_git_write" = "1" ]; then
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
                effective_cwd="/__unresolved_git_C__"
            else
                effective_cwd="$git_c_resolved"
            fi
        fi
        if [ "$has_bypass_shell" != "1" ] && [ "$has_eval" != "1" ] \
            && [ "$has_subshell_git" != "1" ]; then
            case "$effective_cwd" in
                */.claude/worktrees/?*) exit 0 ;;
            esac
        fi
        emit_decision deny "$DENY_GIT_MSG"
        exit 0
    fi

    exit 0
else
    file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

    if [ -z "$file_path" ]; then
        exit 0
    fi

    cwd=$(echo "$INPUT" | jq -r '.cwd // empty')
    [ -n "$cwd" ] || cwd="$HOME"

    resolved_path=$(_resolve_path "$cwd" "$file_path")
    if [ -z "$resolved_path" ]; then
        emit_decision ask "$INTERNAL_ERROR_MSG"
        exit 0
    fi

    case "$resolved_path" in
        "$HOME"/.claude/projects/*/memory/*) exit 0 ;;
    esac

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

    if ! is_in_git_repo "${resolved_path%/*}"; then
        exit 0
    fi

    case "$resolved_path" in
        */.claude/worktrees/*/*) exit 0 ;;
    esac

    emit_decision deny "$DENY_EDIT_MSG"
    exit 0
fi
