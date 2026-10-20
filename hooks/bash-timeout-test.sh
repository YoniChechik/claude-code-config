#!/bin/bash

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRE="$HOOK_DIR/bash-timeout-pre.sh"
POST="$HOOK_DIR/bash-timeout-post.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export BASH_TIMEOUT_SECONDS=2
export BASH_TIMEOUT_STATE_DIR="$WORK/state"
export BASH_TIMEOUT_NOTIFY=0
export BASH_TIMEOUT_SKIP_RTK=1

FAILS=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

pre_payload() {
    jq -cn --arg c "$1" --argjson bg "${2:-false}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,description:"t",run_in_background:$bg}}'
}

rewrite() {
    pre_payload "$1" "${2:-false}" | bash "$PRE" | jq -r '.hookSpecificOutput.updatedInput.command // empty'
}

run_rewritten() {
    local cmd="$1" shell="${2:-bash}"
    (cd "$WORK" && "$shell" -c "$cmd" >"$WORK/out" 2>"$WORK/err")
}

check_passthrough() {
    local name="$1" original="$2" shell="$3" wrapped expected actual rc
    wrapped=$(rewrite "$original")
    if [[ $wrapped != *bash-timeout-run.sh* ]]; then
        fail "$name [$shell]: not wrapped (got: $wrapped)"
        return
    fi
    expected=$(cd "$WORK" && bash -c "$original" 2>&1; printf 'rc=%s' "$?")
    run_rewritten "$wrapped" "$shell"
    rc=$?
    actual=$(cat "$WORK/out" "$WORK/err"; printf 'rc=%s' "$rc")
    if [ "$expected" = "$actual" ]; then
        pass "$name [$shell]"
    else
        fail "$name [$shell]: expected <$expected> got <$actual>"
    fi
}

for sh in bash zsh; do
    command -v "$sh" >/dev/null || continue
    check_passthrough "fast echo" 'echo ok' "$sh"
    check_passthrough "compound" 'cd /tmp && echo a | cat' "$sh"
    check_passthrough "quotes" "echo \"double \$HOME\" 'single \"x\"' \$'tab\\there' it\\'s" "$sh"
    check_passthrough "newlines" $'printf \'%s\\n\' "line one"\nfor i in 1 2; do\n  echo "n=$i"\ndone\necho \'multi\nline literal\'' "$sh"
    check_passthrough "nonzero exit" 'echo before; exit 3' "$sh"
done

if [ "$(run_rewritten "$(rewrite 'echo ok')"; cat "$WORK/out")" = "ok" ]; then pass "echo ok output exact"; else fail "echo ok output exact"; fi

W=$(rewrite 'echo ok')
if [ -z "$(pre_payload "$W" | bash "$PRE" | jq -r '.hookSpecificOutput.updatedInput.command // empty')" ]; then
    pass "already wrapped is not re-wrapped"
else
    fail "already wrapped is not re-wrapped"
fi

CTX=$(pre_payload 'echo ok' | bash "$PRE" | jq -r '.hookSpecificOutput.additionalContext // empty')
if [[ $CTX == *"killed after 2 seconds"* ]]; then pass "pre hook emits nudge with test cap"; else fail "pre hook emits nudge with test cap"; fi
DEFAULT=$(pre_payload 'echo ok' | env -u BASH_TIMEOUT_SECONDS bash "$PRE")
if [[ $(jq -r '.hookSpecificOutput.additionalContext' <<<"$DEFAULT") == *"killed after 30 minutes"* ]] && [[ $(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$DEFAULT") == *"bash-timeout-run.sh' 1785 fg "* ]]; then
    pass "default cap is 1785s plus 15s kill-after (30 minutes)"
else
    fail "default cap is 1785s plus 15s kill-after (got $DEFAULT)"
fi

KEEP=$(pre_payload 'echo ok' true | bash "$PRE" | jq -r '.hookSpecificOutput.updatedInput | "\(.run_in_background) \(.description)"')
if [ "$KEEP" = "true t" ]; then pass "other tool_input fields preserved"; else fail "other tool_input fields preserved (got $KEEP)"; fi

SLEEP_CMD=$(rewrite 'sleep 5')
run_rewritten "$SLEEP_CMD"
RC=$?
if [ "$RC" = "124" ]; then pass "sleep 5 killed with exit 124"; else fail "sleep 5 killed with exit 124 (rc=$RC)"; fi
STDERR=$(cat "$WORK/err")
if [[ $STDERR == *"[bash-timeout] KILLED"* ]]; then pass "kill notice on stderr"; else fail "kill notice on stderr"; fi

POST_FAIL=$(jq -cn --arg c "$SLEEP_CMD" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:$c},error:"Exit code 124\n"}' | bash "$POST")
if [[ $(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$POST_FAIL") == *"KILLED by the"* ]] && [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$POST_FAIL")" = "PostToolUseFailure" ]; then
    pass "post hook (failure event, exit code 124) emits timeout notice"
else
    fail "post hook (failure event) emits timeout notice (got $POST_FAIL)"
fi

POST_OK=$(jq -cn --arg c "$SLEEP_CMD" --arg e "$STDERR" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"",stderr:$e,interrupted:false}}' | bash "$POST")
if [[ $(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$POST_OK") == *"KILLED by the"* ]]; then
    pass "post hook (stderr notice) emits timeout notice"
else
    fail "post hook (stderr notice) emits timeout notice (got $POST_OK)"
fi

POST_QUIET=$(jq -cn '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"echo ok"},tool_response:{stdout:"ok",stderr:"",interrupted:false}}' | bash "$POST")
if [ -z "$POST_QUIET" ]; then pass "post hook silent on normal command"; else fail "post hook silent on normal command"; fi

POST_OTHER=$(jq -cn '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:"exit 124"},error:"Exit code 124"}' | bash "$POST")
if [ -z "$POST_OTHER" ]; then pass "post hook ignores unwrapped exit 124"; else fail "post hook ignores unwrapped exit 124"; fi

run_rewritten "$(rewrite 'exit 124')"
if [ "$?" = "124" ] && [[ $(cat "$WORK/err") != *"[bash-timeout]"* ]]; then pass "command's own fast exit 124 is not reported as a timeout"; else fail "own exit 124 misreported"; fi

rm -rf "$BASH_TIMEOUT_STATE_DIR"
run_rewritten "$(rewrite 'sleep 5' true)"
MARKER=$(find "$BASH_TIMEOUT_STATE_DIR" -name '*.json' 2>/dev/null | head -1)
if [ -n "$MARKER" ] && [ "$(jq -r '"\(.mode) \(.exit_code) \(.command)"' "$MARKER")" = "bg 124 sleep 5" ]; then
    pass "background timeout writes marker"
else
    fail "background timeout writes marker"
fi

unset BASH_TIMEOUT_SKIP_RTK
if command -v rtk >/dev/null && [ "$(rtk hook check 'ls /tmp' 2>/dev/null)" = "rtk ls /tmp" ]; then
    RW=$(rewrite 'ls /tmp')
    if [[ $RW == *bash-timeout-run.sh*"'rtk ls /tmp'" ]]; then pass "rtk rewrite composed inside wrapper"; else fail "rtk rewrite composed inside wrapper (got $RW)"; fi
fi

if ((FAILS == 0)); then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILS FAILED"
exit 1
