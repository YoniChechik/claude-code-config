#!/usr/bin/env bash

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"
: "${GH_MONITOR_RELAY_MAX_AGE_MIN:=1440}"
HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

IFS= read -r -d '' input
mapfile -d '' fields < <(printf '%s' "$input" | jq -j '(.session_id // "" | tostring), "\u0000",
    (.hook_event_name // "" | tostring), "\u0000",
    (.agent_id // "" | tostring), "\u0000"' 2>/dev/null)
((${#fields[@]} == 3)) || exit 0
session=${fields[0]}
event=${fields[1]}
agent=${fields[2]}
[ -n "$session" ] || exit 0
[ -z "$agent" ] || exit 0
case "$event" in
    Stop | PostToolUse) ;;
    *) exit 0 ;;
esac

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
        hook_log "relay($event): result $target --repo $repo"
    else
        text+="${text:+$'\n\n'}PR '${target}' on ${repo} was merged by a subagent or an earlier command in this session, and a detached post-merge watcher is still waiting for every workflow run on its merge commit (CI and the release/deploy cascade). Its deploy is NOT verified yet: do not tell the user that it is deployed, shipped or live, and do not treat a subagent's report as proof, until this watcher's verdict arrives. Unless you already run a background waiter for this PR, call the Bash tool with \`command: ${wait_cmd}\` and \`run_in_background: true\` (no explicit \`timeout\` override). When it completes, report the verdict to the user exactly as printed: the PR number and what it is about, the merge commit sha, and each workflow's conclusion."
        hook_log "relay($event): waiter $target --repo $repo"
    fi
    : >"$meta.announced"
done < <(find "$CLAUDE_NOTIFY_TMP_DIR" -maxdepth 1 -name 'gh_monitor_watch_merge_*.meta' -mmin "-$GH_MONITOR_RELAY_MAX_AGE_MIN" -print0 2>/dev/null)

[ -n "$text" ] || exit 0
hook_json_str "$text"
if [ "$event" = Stop ]; then
    printf '{"decision":"block","reason":%s}\n' "$REPLY"
else
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$REPLY"
fi
