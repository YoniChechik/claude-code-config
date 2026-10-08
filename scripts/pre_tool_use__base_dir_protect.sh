#!/bin/bash

GUARD_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && GUARD_DIR=${BASH_SOURCE[0]%/*}
DENY_GIT_MSG="DENIED: Git write operation attempted outside a git worktree. Direct writes to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that worktree."
DENY_EDIT_MSG="DENIED: File edit/write attempted outside a git worktree inside a git repo. Direct edits to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that worktree. Never edit files directly in the base repo directory."
INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARD_INTERNAL_ERROR: the base-dir guard could not complete its checks, so it is failing closed. Ask the user to run this manually or to repair scripts/_bashparse.sh."}}'
UNSAFE_GIT_CONFIG_RE='^(alias\.|include\.path=|includeif\.|core\.pager=|core\.editor=|core\.sshcommand=|core\.hookspath=|core\.fsmonitor=|uploadpack\.|protocol\.)'
DYN=$'\xef\xbf\xbd'

if [[ ${BP_READY:-} != 1 ]] || ! declare -F bp_hook_prepare >/dev/null; then
    IFS= read -r -d '' INPUT
    if ! source "$GUARD_DIR/_hook_log.sh" 2>/dev/null || ! source "$GUARD_DIR/_bashparse.sh" 2>/dev/null; then
        printf '%s\n' "$INTERNAL_ERROR_JSON"
        exit 0
    fi
    bp_hook_prepare "$INPUT"
fi
((BP_RC == 0)) || exit 0

in_worktree() {
    case "$1" in
        */.claude/worktrees/?*) return 0 ;;
    esac
    return 1
}

all_in_worktree() {
    local d
    (($# > 0)) || return 1
    for d in "$@"; do
        in_worktree "$d" || return 1
    done
    return 0
}

git_branch_args_are_read() {
    local tok expect_value=0 list_mode=0 positional=0
    for tok in "$@"; do
        if [ "$expect_value" = "1" ]; then
            expect_value=0
            continue
        fi
        case "$tok" in
            --contains|--no-contains|--points-at|--merged|--no-merged)
                list_mode=1
                expect_value=1 ;;
            --sort|--format|--color)
                expect_value=1 ;;
            --list|-l|-v|-vv|--verbose|\
            --contains=*|--no-contains=*|--points-at=*|--merged=*|--no-merged=*)
                list_mode=1 ;;
            -a|-r|-q|--all|--remotes|--show-current|--quiet|-i|--ignore-case|--omit-empty|\
            --sort=*|--format=*|--color=*|--no-color) ;;
            -*) return 1 ;;
            *) positional=1 ;;
        esac
    done
    [ "$positional" = "0" ] || [ "$list_mode" = "1" ]
}

git_branch_delete_is_merged() {
    local repo_dir="$1" tok name="" saw_delete=0 head_ref short ref
    shift
    for tok in "$@"; do
        case "$tok" in
            -d|-D|--delete) saw_delete=1 ;;
            -f|--force|-q|--quiet) ;;
            -*|*'*'*|*'?'*|*'['*|*'~'*|*'^'*|*':'*|*'\'*|*'..'*|*"$DYN"*|*[[:space:]]*) return 1 ;;
            *)
                [ -n "$name" ] && return 1
                name="$tok" ;;
        esac
    done
    [ "$saw_delete" = "1" ] && [ -n "$name" ] || return 1
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

git_subcommand_is_read() {
    local sub="$1" repo_dir="$2"
    shift 2
    local first="${1:-}" a
    case "$sub" in
        "")
            return 0 ;;
        status|log|diff|diff-tree|diff-index|difftool|show|blame|annotate|describe|\
        rev-parse|rev-list|ls-files|ls-tree|ls-remote|cat-file|show-ref|for-each-ref|\
        merge-base|name-rev|shortlog|grep|whatchanged|count-objects|check-ignore|\
        check-attr|verify-commit|verify-tag|version|help|cherry|range-diff|\
        show-branch|var|fetch)
            return 0 ;;
        worktree)
            [ "$first" = "list" ] && return 0
            return 1 ;;
        branch)
            git_branch_args_are_read "$@" && return 0
            git_branch_delete_is_merged "$repo_dir" "$@"
            return $? ;;
        config)
            for a in "$@"; do
                case "$a" in
                    --get|--get=*|--get-all|--get-regexp|--get-urlmatch|--list|-l) return 0 ;;
                esac
            done
            case "$first" in
                get|list) return 0 ;;
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
            [ "$#" -eq 2 ] && [ "$1" = "-f" ] && case "$2" in main|master) return 0 ;; esac
            return 1 ;;
        reset)
            [ "$#" -eq 2 ] && [ "$1" = "--hard" ] && case "$2" in origin/main|origin/master) return 0 ;; esac
            return 1 ;;
        clean)
            [ "$#" -eq 1 ] && case "$1" in -fd|-df|-fdx|-fxd|-dfx|-dxf|-xfd|-xdf) return 0 ;; esac
            return 1 ;;
    esac
    return 1
}

git_config_is_unsafe() {
    local c
    for c in "$@"; do
        [[ "$c" == *"$DYN"* ]] && return 0
        [[ "${c,,}" =~ $UNSAFE_GIT_CONFIG_RE ]] && return 0
    done
    return 1
}

VERDICT=""
VERDICT_REASON=""
record() {
    case "$1" in
        deny) [ "$VERDICT" = "deny" ] || { VERDICT=deny; VERDICT_REASON="$2"; } ;;
        ask) [ -n "$VERDICT" ] || { VERDICT=ask; VERDICT_REASON="$2"; } ;;
    esac
}

check_git() {
    local dir unsafe=0
    local -a alts
    git_config_is_unsafe ${SEG_GIT_CONFIG[@]+"${SEG_GIT_CONFIG[@]}"} && unsafe=1
    if [ "$unsafe" = "1" ]; then
        dir="$SEG_CWD"
        alts=(${SEG_CWD_ALTS[@]+"${SEG_CWD_ALTS[@]}"})
    else
        dir="$SEG_GIT_CWD"
        alts=(${SEG_GIT_CWD_ALTS[@]+"${SEG_GIT_CWD_ALTS[@]}"})
        [ "$SEG_GIT_SUB_DYN" = "1" ] || ! git_subcommand_is_read "$SEG_GIT_SUB" "$dir" ${SEG_GIT_ARGS[@]+"${SEG_GIT_ARGS[@]}"} || return 0
    fi
    case "$SEG_FLAGS" in
        *S*|*X*|*F*|*P*) record deny "$DENY_GIT_MSG"; return 0 ;;
    esac
    if [ "$SEG_GIT_OVERRIDE" = "1" ]; then
        record deny "$DENY_GIT_MSG"
    elif all_in_worktree ${alts[@]+"${alts[@]}"}; then
        return 0
    elif [ "${#alts[@]}" = "1" ]; then
        record deny "$DENY_GIT_MSG"
    else
        record ask "The base-dir guard cannot tell which directory this git write runs in (a cd that may fail, a dynamic path, or a cd inside a branch or loop), and at least one candidate is outside a worktree. Confirm manually only if it targets a worktree."
    fi
}

_resolve_path() {
    local p="$2" claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" tilde='~'
    case "$p" in
        "$tilde") p="$HOME" ;;
        "$tilde"/*) p="$HOME/${p#"$tilde"/}" ;;
        '$HOME') p="$HOME" ;;
        '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
        '${HOME}') p="$HOME" ;;
        '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
        '$CLAUDE_CONFIG_DIR') p="$claude_dir" ;;
        '$CLAUDE_CONFIG_DIR/'*) p="$claude_dir/${p#\$CLAUDE_CONFIG_DIR/}" ;;
    esac
    _realpaths "$1" "$p"
}

_realpaths() {
    python3 -c '
import os, sys
base = sys.argv[1]
for p in sys.argv[2:]:
    sys.stdout.write(os.path.realpath(os.path.join(base, p)) + "\0")
' "$@" 2>/dev/null
}

in_base_repo() {
    local p="$1" dir
    case "$p" in
        "$HOME"/.claude/projects/*/memory/*) return 1 ;;
    esac
    case "$p" in
        */.claude/worktrees/*/*) return 1 ;;
        */.claude/worktrees/?*) [ -e "$p/.git" ] && return 1 ;;
    esac
    dir="$p"
    while [ "$dir" != "/" ] && [ -n "$dir" ] && [ ! -e "$dir/.git" ]; do
        dir="${dir%/*}"
    done
    [ -e "$dir/.git" ] || return 1
    [ "$p" = "$dir" ] && return 0
    ! git -C "$dir" check-ignore -q -- "$p" 2>/dev/null
}

check_writes() {
    local t p hits
    local -a cands resolved
    for t in ${SEG_WRITES[@]+"${SEG_WRITES[@]}"}; do
        cands=()
        if [[ $t == /* ]]; then
            cands=("$t")
        else
            for p in ${SEG_CWD_ALTS[@]+"${SEG_CWD_ALTS[@]}"}; do
                cands+=("$p/$t")
            done
        fi
        ((${#cands[@]} > 0)) || continue
        mapfile -d '' resolved < <(_realpaths / "${cands[@]}")
        hits=0
        for p in ${resolved[@]+"${resolved[@]}"}; do
            in_base_repo "$p" && hits=$((hits + 1))
        done
        if ((hits > 0 && hits == ${#resolved[@]})); then
            record deny "$DENY_EDIT_MSG (target: ${resolved[0]})"
        elif ((hits > 0)); then
            record ask "The base-dir guard cannot tell which directory this command writes $t in (a cd that may fail, or a cd inside a branch or loop), and one candidate is in the base repo outside a worktree. Confirm manually only if it targets a worktree."
        fi
    done
}

if [ "$BP_TOOL" = "Bash" ]; then
    for ((seg_i = 0; seg_i < BP_N; seg_i++)); do
        bp_seg "$seg_i"
        check_writes
        [ "$SEG_GIT" = "1" ] && check_git
    done
    if [ -n "$VERDICT" ]; then
        hook_log "$VERDICT: base-dir guard"
        hook_decision "$VERDICT" "$VERDICT_REASON"
    fi
    exit 0
fi

[ -n "$BP_FILE" ] || exit 0
cwd="${BP_CWD:-$HOME}"
mapfile -d '' resolved < <(_resolve_path "$cwd" "$BP_FILE")
((${#resolved[@]} == 1)) || exit 0
in_base_repo "${resolved[0]}" || exit 0
hook_decision deny "$DENY_EDIT_MSG"
exit 0
