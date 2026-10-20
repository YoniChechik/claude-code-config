#!/bin/bash

INPUT=$(cat)

[ "$(jq -r '.tool_name // empty' <<<"$INPUT")" = "Bash" ] || exit 0

TEXT=$(jq -r '[.tool_response.stdout?, .tool_response.stderr?, (.tool_response | strings), .error?] | map(select(. != null)) | join("\n")' <<<"$INPUT" 2>/dev/null)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")

hit=0
case "$TEXT" in
    *"[bash-timeout] KILLED"*) hit=1 ;;
esac
if [ "$hit" = 0 ] && [[ $COMMAND == *bash-timeout-run.sh* ]] && [[ $TEXT =~ (^|[^0-9])[Ee]xit\ code\ (124|137)([^0-9]|$) ]]; then
    hit=1
fi
[ "$hit" = 1 ] || exit 0

LIMIT_TEXT="the 30-minute hard cap"
if [[ $TEXT =~ \[bash-timeout\]\ KILLED\ after\ ([0-9]+)s ]] && [ "${BASH_REMATCH[1]}" != "1785" ]; then
    LIMIT_TEXT="the ${BASH_REMATCH[1]}-second hard cap"
fi
EVENT=$(jq -r '.hook_event_name // "PostToolUse"' <<<"$INPUT")
CTX="This Bash command was KILLED by $LIMIT_TEXT (exit 124). Do not retry it blindly. Tell the user it was killed by that cap and is probably very long-running, log it (Linear ticket or note) so it can be picked up later, and only re-run it if you have concrete evidence it was minutes away from finishing. A marker was written under ~/.claude/logs/bash-timeouts/."

jq -cn --arg e "$EVENT" --arg c "$CTX" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
