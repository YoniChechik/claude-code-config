#!/usr/bin/env bash

set -uo pipefail

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}
ALLOWED_HEADERS='["one-by-one", "plan"]'
DENY_MSG="Not an allowed question. If the answer is observable or the action is pre-approved, do it and report. If it is a real human-only step, start the question text with \`BLOCKED:<category>\`, with a category from: credential, captcha, payment, physical, destructive-prod-data, spending-money, irreversible-external-send, paradigm-shift."
SUBAGENT_MSG="Subagents have no user to ask. Report the open point to the orchestrator in your final report as \`BLOCKED <category>: <ask>\` and stop."

IFS= read -r -d '' input
source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_state.sh" 2>/dev/null || exit 0

verdict=$(printf '%s' "$input" | jq -r --argjson headers "$ALLOWED_HEADERS" '
    def cats: ["credential", "captcha", "payment", "physical", "destructive-prod-data", "spending-money", "irreversible-external-send", "paradigm-shift"];
    def tagged: test("^\\s*BLOCKED\\s*[: ]\\s*(?<c>[a-z-]+)"; "i")
        and ((capture("^\\s*BLOCKED\\s*[: ]\\s*(?<c>[a-z-]+)"; "i").c | ascii_downcase) as $c | cats | index($c) != null);
    if .tool_name != "AskUserQuestion" then "skip"
    elif (.agent_id // "") != "" then "subagent"
    elif ((.tool_input.questions // []) | length) == 0 then "deny"
    elif all(.tool_input.questions[];
        ((.header // "") | ascii_downcase) as $h | ($headers | index($h)) != null
        or ((.question // "") | tagged)) then "allow"
    else "deny" end' 2>/dev/null) || { hook_log "error: bad hook input JSON"; exit 0; }

case "$verdict" in
    skip) exit 0 ;;
    allow) hook_log "allow ask"; exit 0 ;;
    subagent | deny) ;;
    *) hook_log "error: unexpected verdict '$verdict'"; exit 0 ;;
esac

state_enforcing "deny ask: $verdict" "ask" || exit 0
hook_log "deny ask: $verdict"
if [[ $verdict == subagent ]]; then
    hook_decision deny "$SUBAGENT_MSG"
else
    hook_decision deny "$DENY_MSG"
fi
exit 0
