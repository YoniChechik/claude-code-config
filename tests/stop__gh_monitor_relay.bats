#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/stop__gh_monitor_relay.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR"
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
    jq -nc --arg s "$1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | bash "$HOOK"
}

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
    assert_contains "merged PR '3951' on o/r" "$r"
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
