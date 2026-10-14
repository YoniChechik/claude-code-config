#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/gh_monitor_relay.sh"
STOP_HOOK="${BATS_TEST_DIRNAME}/../scripts/stop__coordinator.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export DONE_GATE_MODE=log
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

make_meta() {
    local name="$1" session="$2" target="$3"
    local meta="$BATS_TEST_TMPDIR/gh_monitor_watch_merge_${name}.meta"
    printf 'session=%s\ntarget=%s\nrepo=o/r\nstarted=1\nresult=%s\nwait_cmd=bash /x/gh_monitor.sh wait %s --repo o/r\n' \
        "$session" "$target" "$BATS_TEST_TMPDIR/gh_monitor_result_merge_${name}" "$target" >"$meta"
    printf '%s' "$meta"
}

fire() {
    jq -nc --arg s "$1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | bash "$STOP_HOOK"
}

fire_agent_return() {
    jq -nc --arg s "$1" --arg aid "${2:-}" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Agent",tool_response:{}}
        + (if $aid == "" then {} else {agent_id:$aid} end)' | bash "$HOOK"
}

context() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

reason() { printf '%s' "$1" | jq -r '.reason'; }

@test "nothing to relay emits nothing" {
    run fire s1
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a running subagent-started watch blocks once and tells the main session to start the background waiter" {
    meta=$(make_meta 3951 s1 3951)
    run fire s1
    assert_eq 0 "$status"
    assert_eq block "$(printf '%s' "$output" | jq -r '.decision')"
    r=$(reason "$output")
    assert_contains "PR '3951' on o/r was merged by a subagent" "$r"
    assert_contains "Its deploy is NOT verified yet: do not tell the user that it is deployed, shipped or live, and do not treat a subagent's report as proof" "$r"
    assert_contains "Unless you already run a background waiter for this PR" "$r"
    assert_contains '`command: bash /x/gh_monitor.sh wait 3951 --repo o/r`' "$r"
    assert_contains '`run_in_background: true`' "$r"
    assert_contains "the PR number and what it is about, the merge commit sha, and each workflow's conclusion" "$r"
    [ -e "$meta.announced" ] || { echo "not marked announced" >&2; return 1; }
    run fire s1
    assert_eq "" "$output"
}

@test "a watch that already finished relays its verdict text directly" {
    meta=$(make_meta 3951 s1 3951)
    printf 'Post-merge CI FAILED for PR #3951 "x" on o/r (merge commit abc): 1 of 2 failed\n  failure  Deploy (run 1)\n' \
        >"$BATS_TEST_TMPDIR/gh_monitor_result_merge_3951"
    run fire s1
    r=$(reason "$output")
    assert_contains "has finished" "$r"
    assert_contains 'Post-merge CI FAILED for PR #3951 "x" on o/r (merge commit abc): 1 of 2 failed' "$r"
    assert_contains "failure  Deploy (run 1)" "$r"
}

@test "watches from another session are never relayed" {
    make_meta 3951 other 3951 >/dev/null
    run fire s1
    assert_eq "" "$output"
}

@test "an already-announced watch is not relayed again" {
    meta=$(make_meta 3951 s1 3951)
    : >"$meta.announced"
    run fire s1
    assert_eq "" "$output"
}

@test "several pending watches are relayed together in one block" {
    make_meta 1 s1 101 >/dev/null
    make_meta 2 s1 102 >/dev/null
    run fire s1
    r=$(reason "$output")
    assert_contains "PR '101'" "$r"
    assert_contains "PR '102'" "$r"
}

@test "when a subagent returns, the main session gets the pending watch as PostToolUse context before it replies" {
    meta=$(make_meta 3951 s1 3951)
    run fire_agent_return s1
    assert_eq 0 "$status"
    assert_eq PostToolUse "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    assert_eq null "$(printf '%s' "$output" | jq -r '.decision')"
    c=$(context "$output")
    assert_contains "PR '3951' on o/r was merged by a subagent" "$c"
    assert_contains '`command: bash /x/gh_monitor.sh wait 3951 --repo o/r`' "$c"
    assert_contains "Its deploy is NOT verified yet" "$c"
    [ -e "$meta.announced" ] || { echo "not marked announced" >&2; return 1; }
    run fire s1
    assert_eq "" "$output"
}

@test "a subagent return relays an already-finished verdict as context" {
    make_meta 3951 s1 3951 >/dev/null
    printf 'Post-merge CI passed for PR #3951 "x" on o/r (merge commit abc)\n' \
        >"$BATS_TEST_TMPDIR/gh_monitor_result_merge_3951"
    run fire_agent_return s1
    c=$(context "$output")
    assert_contains "has finished" "$c"
    assert_contains 'Post-merge CI passed for PR #3951 "x" on o/r (merge commit abc)' "$c"
}

@test "hooks fired inside a subagent never relay or consume the watch" {
    meta=$(make_meta 3951 s1 3951)
    run fire_agent_return s1 sub1
    assert_eq "" "$output"
    [ ! -e "$meta.announced" ] || { echo "a subagent hook must not consume the watch" >&2; return 1; }
    jq -nc '{hook_event_name:"Stop",session_id:"s1",agent_id:"sub1"}' | bash "$STOP_HOOK" >"$BATS_TEST_TMPDIR/out"
    assert_eq "" "$(cat "$BATS_TEST_TMPDIR/out")"
    [ ! -e "$meta.announced" ] || { echo "a subagent hook must not consume the watch" >&2; return 1; }
}

@test "other hook events never relay" {
    meta=$(make_meta 3951 s1 3951)
    run bash -c "jq -nc '{hook_event_name:\"SubagentStop\",session_id:\"s1\"}' | bash '$HOOK'"
    assert_eq "" "$output"
    run bash -c "jq -nc '{hook_event_name:\"Stop\",session_id:\"s1\"}' | bash '$HOOK'"
    assert_eq "" "$output"
    [ ! -e "$meta.announced" ] || { echo "must not consume the watch" >&2; return 1; }
}

@test "relays are logged with their event" {
    make_meta 3951 s1 3951 >/dev/null
    fire_agent_return s1 >/dev/null
    assert_contains "relay(PostToolUse): waiter 3951 --repo o/r" "$(cat "$BATS_TEST_TMPDIR/hooks.log")"
}

@test "settings.json wires the relay synchronously on PostToolUse for the Agent tool only; Stop relays through the coordinator" {
    run jq -r '[.hooks.Stop[] | select(any(.hooks[]; .command | endswith("/scripts/gh_monitor_relay.sh")))] | length' "$SETTINGS"
    assert_eq 0 "$output"
    run jq -r '.hooks.PostToolUse[] | select(any(.hooks[]; .command | endswith("/scripts/gh_monitor_relay.sh"))) | .matcher' "$SETTINGS"
    assert_eq "Agent|Task" "$output"
    run jq -r '[.hooks[][] | .hooks[] | select(.command | endswith("/scripts/gh_monitor_relay.sh")) | .async // false] | unique | .[]' "$SETTINGS"
    assert_eq false "$output"
}
