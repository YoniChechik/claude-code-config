#!/usr/bin/env bash

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"
: "${GH_MONITOR_RELAY_MAX_AGE_MIN:=1440}"
HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session" ] || exit 0

source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0

meta_field() {
    local line
    line=$(grep -m 1 "^$2=" "$1" 2>/dev/null) || return 1
    printf '%s' "${line#*=}"
}

text=""
while IFS= read -r -d '' meta; do
    [ "$(meta_field "$meta" session)" = "$session" ] || continue
    [ -e "$meta.announced" ] && continue
    target=$(meta_field "$meta" target)
    repo=$(meta_field "$meta" repo)
    result=$(meta_field "$meta" result)
    wait_cmd=$(meta_field "$meta" wait_cmd)
    if [ -n "$result" ] && [ -s "$result" ]; then
        text+="${text:+$'\n\n'}The post-merge deploy watch for PR '${target}' on ${repo} (merged by a subagent or an earlier command in this session) has finished. Report this verdict to the user — PR number and what it is about, merge commit, and each workflow's conclusion — exactly as printed:"$'\n'"$(cat "$result")"
        hook_log "relay: result $target --repo $repo"
    else
        text+="${text:+$'\n\n'}A subagent or an earlier command in this session merged PR '${target}' on ${repo}, and a detached post-merge watcher is waiting for every workflow run on its merge commit (CI and the release/deploy cascade). Nobody in this session is listening for its verdict yet: call the Bash tool with \`command: ${wait_cmd}\` and \`run_in_background: true\` (no explicit \`timeout\` override). When it completes, report the verdict to the user exactly as printed: the PR number and what it is about, the merge commit sha, and each workflow's conclusion."
        hook_log "relay: waiter $target --repo $repo"
    fi
    : >"$meta.announced"
done < <(find "$CLAUDE_NOTIFY_TMP_DIR" -maxdepth 1 -name 'gh_monitor_watch_merge_*.meta' -mmin "-$GH_MONITOR_RELAY_MAX_AGE_MIN" -print0 2>/dev/null)

[ -n "$text" ] || exit 0
hook_json_str "$text"
printf '{"decision":"block","reason":%s}\n' "$REPLY"
