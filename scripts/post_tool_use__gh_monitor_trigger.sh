#!/usr/bin/env bash

: "${GH_MONITOR_HOOK_TIMEOUT:=5}"
HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input

case "$input" in
    *git*push* | *gh*pr*create* | *gh*pr*merge*) ;;
    *) exit 0 ;;
esac

source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_bashparse.sh" 2>/dev/null || skip "bashparse library missing"

mapfile -d '' resp < <(printf '%s' "$input" | jq -j '(.tool_name // "" | tostring), "\u0000",
    (.tool_response.exit_code // "" | tostring), "\u0000",
    ((.tool_response.stdout // "" | tostring) + "\n" + (.tool_response.stderr // "" | tostring)), "\u0000"' 2>/dev/null)
((${#resp[@]} == 3)) || skip "bad hook input JSON"
[[ ${resp[0]} == Bash ]] || exit 0
EXIT_CODE=${resp[1]}
OUTPUT=${resp[2]}

bp_parse_hook "$input" || skip "parse failed: $BP_ERR"

bp_find git push && PUSHES=("${BP_MATCHES[@]}") || PUSHES=()
bp_find gh pr create && CREATES=("${BP_MATCHES[@]}") || CREATES=()
bp_find gh pr merge && MERGES=("${BP_MATCHES[@]}") || MERGES=()
((${#PUSHES[@]} + ${#CREATES[@]} + ${#MERGES[@]} > 0)) || exit 0

run_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" "$@"
        return $?
    fi
    local had_m=0
    case "$-" in *m*) had_m=1 ;; esac
    set -m
    "$@" &
    local pid=$!
    [ "$had_m" = "1" ] || set +m
    (
        local i
        for ((i = 0; i < secs; i++)); do
            kill -0 -- -"$pid" 2>/dev/null || exit 0
            sleep 1
        done
        kill -TERM -- -"$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local watchdog=$!
    local rc=0
    wait "$pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$rc"
}

in_dir() {
    local dir="$1"
    shift
    (cd "$dir" 2>/dev/null && run_timeout "$GH_MONITOR_HOOK_TIMEOUT" "$@" 2>/dev/null)
}

note_skip() {
    hook_log "skip: $1"
    return 1
}

resolve_branch() {
    [ -d "$1" ] || note_skip "cwd does not exist: $1" || return
    BRANCH=$(in_dir "$1" git branch --show-current)
    [ -n "$BRANCH" ] || note_skip "could not resolve the current branch in $1"
}

has_help_flag() {
    local w
    for w in "${SEG_ARGV[@]}"; do
        case "$w" in -h | --help | --help=*) return 0 ;; esac
    done
    return 1
}

common_gate() {
    has_help_flag && { note_skip "$1: help flag"; return; }
    case "$SEG_FLAGS" in
        *B*) note_skip "$1: backgrounded"; return ;;
        *N*) note_skip "$1: negated"; return ;;
    esac
    return 0
}

safe_word() {
    [[ $1 =~ ^[A-Za-z0-9._/#:+@-]+$ ]]
}

INSTR_KEYS=()
INSTR_REPOS=()
INSTR_LEADS=()
add_instruction() {
    local kind="$1" selector="$2" repo="$3" lead="$4" k
    safe_word "$selector" || { note_skip "$kind: unsafe selector $selector"; return; }
    [ -z "$repo" ] || safe_word "$repo" || { note_skip "$kind: unsafe repo $repo"; return; }
    for k in "${!INSTR_KEYS[@]}"; do
        if [ "${INSTR_KEYS[k]}" = "$kind|$selector" ]; then
            [ -n "${INSTR_REPOS[k]}" ] || INSTR_REPOS[k]="$repo"
            return 0
        fi
    done
    INSTR_KEYS+=("$kind|$selector")
    INSTR_REPOS+=("$repo")
    INSTR_LEADS+=("$lead")
}

pr_state() {
    local dir="$1" state rc
    shift
    state=$(in_dir "$dir" gh pr view "$@" --json state -q .state)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        note_skip "gh pr view failed (rc=$rc) for $1"
        return 1
    fi
    PR_STATE=${state//[[:space:]]/}
}

handle_push() {
    bp_seg "$1"
    common_gate push || return
    [[ $SEG_DYN != *1* ]] || { note_skip "push: dynamic argument"; return; }
    [ "$SEG_GIT_OVERRIDE" = "0" ] || { note_skip "push: --git-dir/--work-tree override"; return; }
    [ "$SEG_GIT_CWD_KNOWN" = "1" ] || { note_skip "push: unknown directory"; return; }
    local attrib=0 dir="$SEG_GIT_CWD" t
    local -a positional=()
    [[ $SEG_FLAGS == *A* ]] && attrib=1
    if ((attrib)) && [ "$EXIT_CODE" != "0" ]; then note_skip "push: exit code $EXIT_CODE"; return; fi
    case "$OUTPUT" in *"Everything up-to-date"*) note_skip "push: everything up-to-date"; return ;; esac
    for t in "${SEG_GIT_ARGS[@]}"; do
        case "$t" in
            -f | --force | --force-with-lease | --force-with-lease=* | -u | --set-upstream | -q | --quiet | -v | --verbose | --no-verify | --progress) ;;
            -*) note_skip "push: unsupported flag $t"; return ;;
            *) positional+=("$t") ;;
        esac
    done
    resolve_branch "$dir" || return
    case "${#positional[@]}" in
        0) ;;
        2)
            case "${positional[0]}" in *:* | */*) note_skip "push: remote is a URL or path"; return ;; esac
            [ "${positional[1]}" = "$BRANCH" ] || [ "${positional[1]}" = "HEAD" ] || { note_skip "push: refspec ${positional[1]} is not the current branch"; return; }
            ;;
        *) note_skip "push: ${#positional[@]} positional arguments"; return ;;
    esac
    if ((!attrib)); then
        local heads
        heads=$(in_dir "$dir" git rev-parse HEAD '@{push}')
        [[ $heads == *$'\n'* && ${heads%%$'\n'*} == "${heads#*$'\n'}" ]] || { note_skip "push: exit code not attributable and HEAD != @{push}"; return; }
    fi
    pr_state "$dir" "$BRANCH" || return
    [ "$PR_STATE" = "OPEN" ] || { note_skip "push: PR state $PR_STATE"; return; }
    add_instruction push "$BRANCH" "" "A \`git push\` to '${BRANCH}' with an open PR just succeeded."
}

handle_create() {
    bp_seg "$1"
    common_gate create || return
    [ "$SEG_CWD_KNOWN" = "1" ] || { note_skip "create: unknown directory"; return; }
    local i t repo="" head="" url_repo="" dyn
    resolve_branch "$SEG_CWD" || return
    for ((i = 3; i < ${#SEG_ARGV[@]}; i++)); do
        t="${SEG_ARGV[i]}"
        dyn="${SEG_DYN:i:1}"
        case "$t" in
            --repo | -R) i=$((i + 1)); repo="${SEG_ARGV[i]:-}"; [ "${SEG_DYN:i:1}" = "0" ] && [ -n "$repo" ] || { note_skip "create: bad --repo"; return; } ;;
            --repo=*) [ "$dyn" = "0" ] || { note_skip "create: dynamic --repo"; return; }; repo="${t#--repo=}" ;;
            --head | -H) i=$((i + 1)); head="${SEG_ARGV[i]:-}"; [ "${SEG_DYN:i:1}" = "0" ] || { note_skip "create: dynamic --head"; return; } ;;
            --head=*) [ "$dyn" = "0" ] || { note_skip "create: dynamic --head"; return; }; head="${t#--head=}" ;;
            -t | --title | -b | --body | -F | --body-file | -B | --base | -a | --assignee | -l | --label | -r | --reviewer | -m | --milestone | -p | --project | -T | --template) i=$((i + 1)) ;;
            -*) ;;
            *) note_skip "create: positional argument $t"; return ;;
        esac
    done
    [ -z "$head" ] || [ "$head" = "$BRANCH" ] || { note_skip "create: --head $head is not the current branch"; return; }
    if [[ $OUTPUT =~ https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/[0-9]+ ]] && [[ $OUTPUT != *"already exists"* ]]; then
        url_repo="${BASH_REMATCH[1]}"
    elif [[ $SEG_FLAGS != *A* ]]; then
        note_skip "create: exit code not attributable and no PR URL in the output"
        return
    elif [ "$EXIT_CODE" != "0" ]; then
        note_skip "create: exit code $EXIT_CODE"
        return
    fi
    add_instruction push "$BRANCH" "${repo:-$url_repo}" "A \`gh pr create\` for '${BRANCH}' just succeeded, so its PR is open."
}

handle_merge() {
    bp_seg "$1"
    common_gate merge || return
    local i t repo="" target=""
    for ((i = 3; i < ${#SEG_ARGV[@]}; i++)); do
        t="${SEG_ARGV[i]}"
        case "$t" in
            --repo | -R) i=$((i + 1)); repo="${SEG_ARGV[i]:-}"; [ "${SEG_DYN:i:1}" = "0" ] && [ -n "$repo" ] || { note_skip "merge: bad --repo"; return; } ;;
            --repo=*) [ "${SEG_DYN:i:1}" = "0" ] || { note_skip "merge: dynamic --repo"; return; }; repo="${t#--repo=}" ;;
            -b | --body | -F | --body-file | -t | --subject | --match-head-commit | --author-email) i=$((i + 1)) ;;
            -*) ;;
            *)
                [ "${SEG_DYN:i:1}" = "0" ] || { note_skip "merge: dynamic target"; return; }
                [ -z "$target" ] || { note_skip "merge: two positional arguments"; return; }
                target="$t"
                ;;
        esac
    done
    local dir="$SEG_CWD"
    if [ -z "$target" ] || [ -z "$repo" ]; then
        [ "$SEG_CWD_KNOWN" = "1" ] || { note_skip "merge: unknown directory"; return; }
    fi
    if [ -z "$target" ]; then
        resolve_branch "$dir" || return
        target="$BRANCH"
    fi
    [ -d "$dir" ] || dir=/
    local -a view=("$target")
    [ -z "$repo" ] || view+=(--repo "$repo")
    pr_state "$dir" "${view[@]}" || return
    [ "$PR_STATE" = "MERGED" ] || { note_skip "merge: PR state $PR_STATE"; return; }
    add_instruction merge "$target" "$repo" "A \`gh pr merge\` of '${target}' just succeeded."
}

for i in "${PUSHES[@]}"; do handle_push "$i"; done
for i in "${CREATES[@]}"; do handle_create "$i"; done
for i in "${MERGES[@]}"; do handle_merge "$i"; done

((${#INSTR_KEYS[@]} > 0)) || exit 0

text=""
for k in "${!INSTR_KEYS[@]}"; do
    kind="${INSTR_KEYS[k]%%|*}"
    selector="${INSTR_KEYS[k]#*|}"
    repo_flag=""
    [ -z "${INSTR_REPOS[k]}" ] || repo_flag=" --repo '${INSTR_REPOS[k]}'"
    text+="${text:+$'\n\n'}${INSTR_LEADS[k]} Launch the $kind watcher: call the Bash tool with \`command: bash ~/.claude/scripts/gh_monitor.sh $kind '$selector'$repo_flag\` and \`run_in_background: true\` (no explicit \`timeout\` override — this watcher ends only on a real CI result, not a time box). You do not need to check for an existing watcher first — the script's own lock evicts any stale one automatically."
    hook_log "trigger: $kind $selector${INSTR_REPOS[k]:+ --repo ${INSTR_REPOS[k]}}"
done

hook_json_str "$text"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$REPLY"
