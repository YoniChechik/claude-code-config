#!/usr/bin/env bash

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"
: "${GH_MONITOR_RELAY_MAX_AGE_MIN:=1440}"

relay_meta_field() {
    local line
    line=$(grep -m 1 "^$2=" "$1" 2>/dev/null) || return 1
    printf '%s' "${line#*=}"
}

relay_collect() {
    local session=$1 event=$2 meta target repo result wait_cmd
    RELAY_TEXT=""
    while IFS= read -r -d '' meta; do
        [ "$(relay_meta_field "$meta" session)" = "$session" ] || continue
        [ -e "$meta.announced" ] && continue
        target=$(relay_meta_field "$meta" target)
        repo=$(relay_meta_field "$meta" repo)
        result=$(relay_meta_field "$meta" result)
        wait_cmd=$(relay_meta_field "$meta" wait_cmd)
        if [ -n "$result" ] && [ -s "$result" ]; then
            RELAY_TEXT+="${RELAY_TEXT:+$'\n\n'}The post-merge deploy watch for PR '${target}' on ${repo} (merged by a subagent or an earlier command in this session) has finished. Report this verdict to the user — PR number and what it is about, merge commit, and each workflow's conclusion — exactly as printed:"$'\n'"$(cat "$result")"
            hook_log "relay($event): result $target --repo $repo"
        else
            RELAY_TEXT+="${RELAY_TEXT:+$'\n\n'}PR '${target}' on ${repo} was merged by a subagent or an earlier command in this session, and a detached post-merge watcher is still waiting for every workflow run on its merge commit (CI and the release/deploy cascade). Its deploy is NOT verified yet: do not tell the user that it is deployed, shipped or live, and do not treat a subagent's report as proof, until this watcher's verdict arrives. Unless you already run a background waiter for this PR, call the Bash tool with \`command: ${wait_cmd}\` and \`run_in_background: true\` (no explicit \`timeout\` override). When it completes, report the verdict to the user exactly as printed: the PR number and what it is about, the merge commit sha, and each workflow's conclusion."
            hook_log "relay($event): waiter $target --repo $repo"
        fi
        : >"$meta.announced"
    done < <(find "$CLAUDE_NOTIFY_TMP_DIR" -maxdepth 1 -name 'gh_monitor_watch_merge_*.meta' -mmin "-$GH_MONITOR_RELAY_MAX_AGE_MIN" -print0 2>/dev/null)
}
