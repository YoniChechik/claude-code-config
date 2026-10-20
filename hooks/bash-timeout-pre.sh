#!/bin/bash

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$HOOK_DIR/bash-timeout-run.sh"
SECONDS_CAP="${BASH_TIMEOUT_SECONDS:-1785}"

INPUT=$(cat)
LIMIT_TEXT="30 minutes"
[ "$SECONDS_CAP" = "1785" ] || LIMIT_TEXT="${SECONDS_CAP} seconds"

NUDGE="Bash hard cap: every command is killed after $LIMIT_TEXT (exit 124). Do not start checks that may run longer than that. If a check is nearly done when killed, re-run it once. If it would need more than $LIMIT_TEXT, stop, tell the user it is probably very long-running, log it (Linear ticket or note), and come back to it later."

emit() {
    jq -c --arg cmd "$1" --arg ctx "$2" '{hookSpecificOutput:({hookEventName:"PreToolUse",additionalContext:$ctx} + (if $cmd == "" then {} else {updatedInput:(.tool_input + {command:$cmd})} end))}' <<<"$INPUT"
}

wait_for_sibling_rtk() {
    local tries=0
    while ((tries < 40)) && pgrep -P "$PPID" -f '^rtk hook claude' >/dev/null 2>&1; do
        sleep 0.05
        tries=$((tries + 1))
    done
    sleep 0.1
}

[ "$(jq -r '.tool_name // empty' <<<"$INPUT")" = "Bash" ] || exit 0
ORIGINAL=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
[ -n "$ORIGINAL" ] || exit 0

case "$ORIGINAL" in
    "bash $RUNNER "* | "bash '$RUNNER' "*) exit 0 ;;
esac

if ! command -v gtimeout >/dev/null 2>&1; then
    emit "" "Bash timeout wrapper inactive: gtimeout is not installed. Run \`brew install coreutils\` in its own Bash call to restore the 30-minute cap."
    exit 0
fi

COMMAND="$ORIGINAL"
if [ "${BASH_TIMEOUT_SKIP_RTK:-0}" != "1" ] && command -v rtk >/dev/null 2>&1; then
    REWRITTEN=$(printf '%s' "$INPUT" | rtk hook claude 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
    [ -n "$REWRITTEN" ] && COMMAND="$REWRITTEN"
fi

MODE="fg"
[ "$(jq -r '.tool_input.run_in_background // false' <<<"$INPUT")" = "true" ] && MODE="bg"

WRAPPED=$(jq -rn --arg r "$RUNNER" --arg s "$SECONDS_CAP" --arg m "$MODE" --arg c "$COMMAND" '"bash \($r | @sh) \($s) \($m) \($c | @sh)"')

[ "${BASH_TIMEOUT_SKIP_RTK:-0}" = "1" ] || wait_for_sibling_rtk

emit "$WRAPPED" "$NUDGE"
