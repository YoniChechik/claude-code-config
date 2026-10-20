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
    jq -cn --arg c "$1" --argjson bg "${2:-false}" --arg id "${3:-toolu_test}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c,description:"t",run_in_background:$bg}}'
}

rewrite() {
    pre_payload "$1" "${2:-false}" "${3:-toolu_test}" | bash "$PRE" | jq -r '.hookSpecificOutput.updatedInput.command // empty'
}

post_failure() {
    jq -cn --arg c "$1" --arg id "$2" --arg err "$3" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c},error:$err}' | bash "$POST"
}

post_success() {
    jq -cn --arg c "$1" --arg id "$2" --arg out "$3" --arg err "$4" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c},tool_response:{stdout:$out,stderr:$err,interrupted:false}}' | bash "$POST"
}

has_notice() {
    [[ $(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1" 2>/dev/null) == *"KILLED by the"* ]]
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
if [[ $(jq -r '.hookSpecificOutput.additionalContext' <<<"$DEFAULT") == *"killed after 30 minutes"* ]] && [[ $(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$DEFAULT") == *"bash-timeout-run.sh' 1785 fg toolu_test "* ]]; then
    pass "default cap is 1785s plus 15s kill-after (30 minutes)"
else
    fail "default cap is 1785s plus 15s kill-after (got $DEFAULT)"
fi

KEEP=$(pre_payload 'echo ok' true | bash "$PRE" | jq -r '.hookSpecificOutput.updatedInput | "\(.run_in_background) \(.description)"')
if [ "$KEEP" = "true t" ]; then pass "other tool_input fields preserved"; else fail "other tool_input fields preserved (got $KEEP)"; fi

SLEEP_CMD=$(rewrite 'sleep 5' false toolu_sleep)
run_rewritten "$SLEEP_CMD"
RC=$?
if [ "$RC" = "124" ]; then pass "sleep 5 killed with exit 124"; else fail "sleep 5 killed with exit 124 (rc=$RC)"; fi
STDERR=$(cat "$WORK/err")
if [[ $STDERR == *"[bash-timeout] KILLED"* ]]; then pass "kill notice on stderr"; else fail "kill notice on stderr"; fi

POST_FAIL=$(post_failure "$SLEEP_CMD" toolu_sleep $'Exit code 124\n'"$STDERR")
if has_notice "$POST_FAIL" && [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$POST_FAIL")" = "PostToolUseFailure" ] && [[ $POST_FAIL == *"2-second hard cap"* ]]; then
    pass "real sleep 5 under 2s cap: post hook emits timeout notice"
else
    fail "real sleep 5 under 2s cap: post hook emits timeout notice (got $POST_FAIL)"
fi

POST_OTHER_ID=$(post_failure "$SLEEP_CMD" toolu_other $'Exit code 124\n'"$STDERR")
if [ -z "$POST_OTHER_ID" ]; then pass "post hook ignores exit 124 from a different tool_use_id"; else fail "post hook ignores exit 124 from a different tool_use_id (got $POST_OTHER_ID)"; fi

ECHO_CMD=$(rewrite "echo '[bash-timeout] KILLED after 2s (exit 124, fg): the 30-minute Bash cap was hit.'; echo 'Exit code 124'" false toolu_echo)
run_rewritten "$ECHO_CMD"
ECHO_RC=$?
POST_ECHO=$(post_success "$ECHO_CMD" toolu_echo "$(cat "$WORK/out")" "$(cat "$WORK/err")")
if [ "$ECHO_RC" = "0" ] && [ -z "$POST_ECHO" ]; then
    pass "printing the kill marker text with exit 0 produces no notice"
else
    fail "printing the kill marker text with exit 0 produces no notice (rc=$ECHO_RC got $POST_ECHO)"
fi

GREP_OUT=$(grep -n "KILLED" "$HOOK_DIR/bash-timeout-run.sh" "$HOOK_DIR/bash-timeout-post.sh")
POST_GREP=$(post_success 'grep -n "KILLED" bash-timeout-post.sh' toolu_grep "$GREP_OUT" "")
if [ -z "$POST_GREP" ]; then pass "grepping the hooks for KILLED produces no notice"; else fail "grepping the hooks for KILLED produces no notice (got $POST_GREP)"; fi

OWN_CMD=$(rewrite "echo '[bash-timeout] KILLED after 2s'; exit 124" false toolu_own)
run_rewritten "$OWN_CMD"
OWN_RC=$?
POST_OWN=$(post_failure "$OWN_CMD" toolu_own $'Exit code 124\n'"$(cat "$WORK/out" "$WORK/err")")
if [ "$OWN_RC" = "124" ] && [[ $(cat "$WORK/err") != *"[bash-timeout]"* ]] && [ -z "$POST_OWN" ]; then
    pass "command's own fast exit 124 produces no notice"
else
    fail "command's own fast exit 124 produces no notice (rc=$OWN_RC got $POST_OWN)"
fi

POST_UNWRAPPED=$(post_failure 'exit 124' toolu_unwrapped 'Exit code 124')
if [ -z "$POST_UNWRAPPED" ]; then pass "post hook ignores unwrapped exit 124"; else fail "post hook ignores unwrapped exit 124"; fi

POST_NOID=$(jq -cn --arg c "$SLEEP_CMD" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:$c},error:"Exit code 124"}' | bash "$POST")
if [ -z "$POST_NOID" ]; then pass "post hook silent without tool_use_id"; else fail "post hook silent without tool_use_id"; fi

POST_QUIET=$(post_success 'echo ok' toolu_quiet ok "")
if [ -z "$POST_QUIET" ]; then pass "post hook silent on normal command"; else fail "post hook silent on normal command"; fi

rm -rf "$BASH_TIMEOUT_STATE_DIR"
run_rewritten "$(rewrite 'sleep 5' true toolu_bg)"
MARKER=$(find "$BASH_TIMEOUT_STATE_DIR" -name '*.json' 2>/dev/null | head -1)
if [ -n "$MARKER" ] && [ "$(jq -r '"\(.mode) \(.exit_code) \(.tool_use_id) \(.command)"' "$MARKER")" = "bg 124 toolu_bg sleep 5" ]; then
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
