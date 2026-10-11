#!/bin/bash

GUARD_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && GUARD_DIR=${BASH_SOURCE[0]%/*}
DENY_GIT_MSG="DENIED: Git write operation attempted outside a git worktree. Direct writes to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt your git operation inside that worktree."
DENY_EDIT_MSG="DENIED: File edit/write attempted outside a git worktree inside a git repo. Direct edits to the base repo are forbidden. You MUST use the worktree+PR workflow: (1) For feature/implementation work, run '/create-worktree <feature-description>' then follow the Feature Development — MANDATORY WORKFLOW (plan → implement → test → review → PR → merge → validate). For a non-feature one-off with no PR planned, run '/create-worktree <feature-description>' directly instead — this creates an isolated git worktree under .claude/worktrees/<feature-name>/ on a new branch and switches your working directory into it. (2) Re-attempt the file edit inside that worktree. Never edit files directly in the base repo directory."
INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GUARD_INTERNAL_ERROR: the base-dir guard could not load scripts/_hook_log.sh or scripts/_bashparse.sh, so it is failing closed. Rewriting the command will not help: stop and tell the user the guard libraries next to scripts/pre_tool_use__base_dir_protect.sh are missing or broken and must be repaired."}}'
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

repo_root() {
    REPO_ROOT="$1"
    while [ "$REPO_ROOT" != "/" ] && [ -n "$REPO_ROOT" ] && [ ! -e "$REPO_ROOT/.git" ]; do
        REPO_ROOT="${REPO_ROOT%/*}"
    done
    [ -e "$REPO_ROOT/.git" ]
}

all_outside_base() {
    local d
    (($# > 0)) || return 1
    for d in "$@"; do
        in_worktree "$d" && continue
        repo_root "$d" && return 1
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

VERDICT_REASON=""
record_deny() {
    [ -n "$VERDICT_REASON" ] || VERDICT_REASON="$1"
}

CD_PROBLEMS=""
CD_N=0
add_problem() {
    CD_N=$((CD_N + 1))
    CD_PROBLEMS+="${CD_PROBLEMS:+ }($CD_N) $1"
}

shown() {
    printf '%s' "${1//$DYN/<dynamic>}"
}

collect_cd_problems() {
    local i=$1 j k tgt dyn frag
    CD_PROBLEMS=""
    CD_N=0
    for ((j = 0; j < i; j++)); do
        bp_seg "$j"
        [[ $SEG_FLAGS == *X* ]] && continue
        case "$SEG_CMD" in
            pushd|popd|source|.|eval)
                add_problem "\`$(shown "${SEG_RAW[*]}")\` changes the working directory in a way the guard cannot follow; remove it."
                continue ;;
            cd) ;;
            *) continue ;;
        esac
        tgt="" dyn=0
        for ((k = 1; k < ${#SEG_ARGV[@]}; k++)); do
            [[ ${SEG_DYN:k:1} == 0 ]] && case "${SEG_ARGV[k]}" in -L|-P|-e|-@|--) continue ;; esac
            tgt=${SEG_ARGV[k]}
            dyn=${SEG_DYN:k:1}
            break
        done
        frag="\`$(shown "${SEG_RAW[*]}")\`"
        if [[ $SEG_FLAGS == *[CFG]* ]]; then
            add_problem "$frag runs inside an if/for/while/case block, a { } group, or a function, so whether it ran is unknown; never cd inside a branch or loop before a git write."
        elif [[ $dyn == 1 || $tgt == *"$DYN"* || $tgt == "-" || $tgt == *'$'* ]]; then
            add_problem "$frag has a dynamic target (variable, \$(...), glob, or cd -) the guard cannot resolve; write the literal absolute path instead."
        elif [[ -z $tgt ]]; then
            add_problem "$frag has no target; write the literal absolute path instead."
        elif [[ $tgt != /* ]]; then
            add_problem "$frag is a relative cd, so the guard cannot be sure it succeeded or where it landed; use a literal absolute path, never cd .. or cd <subdir>."
        elif [[ ! -d $tgt ]]; then
            add_problem "$frag targets a directory that does not exist, so the cd may fail and leave the shell in the base repo; create the worktree first or cd to an existing worktree path."
        fi
    done
    bp_seg "$i"
}

git_c_problems() {
    local k v
    for ((k = 1; k < ${#SEG_RAW[@]}; k++)); do
        [ "${SEG_RAW[k - 1]}" = "-C" ] || continue
        v=${SEG_RAW[k]}
        [[ $v == /* && $v != *"$DYN"* ]] && continue
        add_problem "\`git -C $(shown "$v")\` is not a literal absolute path; pass the full absolute worktree path."
    done
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
        *S*|*X*|*F*|*P*) record_deny "$DENY_GIT_MSG"; return 0 ;;
    esac
    if [ "$SEG_GIT_OVERRIDE" = "1" ]; then
        record_deny "$DENY_GIT_MSG"
    elif all_outside_base ${alts[@]+"${alts[@]}"}; then
        return 0
    elif [ "${#alts[@]}" = "1" ]; then
        record_deny "$DENY_GIT_MSG"
    else
        collect_cd_problems "$seg_i"
        git_c_problems
        record_deny "DENIED: the base-dir guard cannot prove which directory \`git $(shown "$SEG_GIT_SUB")\` runs in, and at least one possible directory is outside a worktree. Problems: ${CD_PROBLEMS:-the starting directory could not be determined (a cd chained after a command that may fail, a CDPATH lookup, or a shell function call).} Rewrite: drop every cd before the git write and run each git write as its own Bash call with a literal absolute worktree path, e.g. \`git -C /abs/path/.claude/worktrees/<name> add -A\`, then a separate \`git -C /abs/path/.claude/worktrees/<name> commit -m ...\`, then \`git -C /abs/path/.claude/worktrees/<name> push ...\`. Never use relative cd (cd .., cd subdir), variables, \$(...), ~, or globs in a cd or -C path, and never put a cd inside an if/for/while/case block or after || / && before a git write. Run non-git steps (tests, builds) in a separate Bash call."
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
    local p="$1"
    case "$p" in
        "$HOME"/.claude/projects/*/memory/*) return 1 ;;
    esac
    case "$p" in
        */.claude/worktrees/*/*) return 1 ;;
        */.claude/worktrees/?*) [ -e "$p/.git" ] && return 1 ;;
    esac
    repo_root "$p" || return 1
    [ "$p" = "$REPO_ROOT" ] && return 0
    ! git -C "$REPO_ROOT" check-ignore -- "$p" "$p/" >/dev/null 2>&1
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
            record_deny "$DENY_EDIT_MSG (target: ${resolved[0]})"
        elif ((hits > 0)); then
            collect_cd_problems "$seg_i"
            record_deny "DENIED: the base-dir guard cannot prove where this command writes $t, and one possible location is in the base repo outside a worktree. Problems: ${CD_PROBLEMS:-the starting directory could not be determined (a cd chained after a command that may fail, a CDPATH lookup, or a shell function call).} Rewrite: write to a literal absolute path inside a worktree, e.g. \`... > /abs/path/.claude/worktrees/<name>/$t\`, and drop the cd. Never use relative cd (cd .., cd subdir), variables, \$(...), ~, or globs in a cd target, and never put a cd inside an if/for/while/case block or after || / && before the write."
        fi
    done
}

if [ "$BP_TOOL" = "Bash" ]; then
    for ((seg_i = 0; seg_i < BP_N; seg_i++)); do
        bp_seg "$seg_i"
        check_writes
        [ "$SEG_GIT" = "1" ] && check_git
    done
    if [ -n "$VERDICT_REASON" ]; then
        hook_log "deny: base-dir guard"
        hook_decision deny "$VERDICT_REASON"
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
