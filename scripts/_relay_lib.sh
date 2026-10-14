#!/usr/bin/env bash

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"
: "${GH_MONITOR_RELAY_MAX_AGE_MIN:=1440}"

RELAY_LIB_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && RELAY_LIB_DIR=${BASH_SOURCE[0]%/*}
declare -F hook_log >/dev/null || source "$RELAY_LIB_DIR/_hook_log.sh" || return 1
declare -F state_safe_file >/dev/null || source "$RELAY_LIB_DIR/_state.sh" || return 1

relay_owned_file() {
    [[ -f $1 ]] && state_safe_file "$1"
}

relay_read_meta() {
    local k v
    META_session=""
    META_target=""
    META_repo=""
    META_result=""
    META_wait_cmd=""
    relay_owned_file "$1" || { hook_log "relay: untrusted meta file: ${STATE_ERR:-not a regular file: $1}"; return 1; }
    while IFS='=' read -r k v; do
        case "$k" in
            session | target | repo | result | wait_cmd) printf -v "META_$k" '%s' "$v" ;;
        esac
    done <"$1"
}

relay_result_text() {
    REPLY=""
    case "$1" in
        "$CLAUDE_NOTIFY_TMP_DIR"/gh_monitor_result_merge_*) ;;
        *) [[ -z $1 ]] || hook_log "relay: result path outside the notify dir: $1"; return 1 ;;
    esac
    [[ -s $1 ]] || return 1
    relay_owned_file "$1" || { hook_log "relay: untrusted result file: $STATE_ERR"; return 1; }
    REPLY=$(<"$1")
}

relay_collect() {
    local session=$1 event=$2 meta marker
    RELAY_TEXT=""
    while IFS= read -r -d '' meta; do
        marker="$meta.announced"
        [[ -e $marker || -L $marker ]] && continue
        relay_read_meta "$meta" || continue
        [[ $META_session == "$session" ]] || continue
        if relay_result_text "$META_result"; then
            RELAY_TEXT+="${RELAY_TEXT:+$'\n\n'}The post-merge deploy watch for PR '${META_target}' on ${META_repo} (merged by a subagent or an earlier command in this session) has finished. Report this verdict to the user — PR number and what it is about, merge commit, and each workflow's conclusion — exactly as printed:"$'\n'"$REPLY"
            hook_log "relay($event): result $META_target --repo $META_repo"
        else
            RELAY_TEXT+="${RELAY_TEXT:+$'\n\n'}PR '${META_target}' on ${META_repo} was merged by a subagent or an earlier command in this session, and a detached post-merge watcher is still waiting for every workflow run on its merge commit (CI and the release/deploy cascade). Its deploy is NOT verified yet: do not tell the user that it is deployed, shipped or live, and do not treat a subagent's report as proof, until this watcher's verdict arrives. Unless you already run a background waiter for this PR, call the Bash tool with \`command: ${META_wait_cmd}\` and \`run_in_background: true\` (no explicit \`timeout\` override). When it completes, report the verdict to the user exactly as printed: the PR number and what it is about, the merge commit sha, and each workflow's conclusion."
            hook_log "relay($event): waiter $META_target --repo $META_repo"
        fi
        (set -C && : >"$marker") 2>/dev/null || hook_log "relay: cannot create $marker"
    done < <(find "$CLAUDE_NOTIFY_TMP_DIR" -maxdepth 1 -name 'gh_monitor_watch_merge_*.meta' -type f -user "$UID" -mmin "-$GH_MONITOR_RELAY_MAX_AGE_MIN" -print0 2>/dev/null)
}
