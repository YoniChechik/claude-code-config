#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/config_change__guard.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export DONE_GATE_MODE=enforce
    NEW="$BATS_TEST_TMPDIR/settings.json"
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

change() {
    jq -nc --arg f "$NEW" --arg s "${1:-user_settings}" '{hook_event_name: "ConfigChange", session_id: "s1", source: $s, file_path: $f}' | bash "$HOOK"
}

@test "the repo settings.json keeps every gate hook, so a change to it is allowed" {
    cp "$SETTINGS" "$NEW"
    run change
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "removing the Stop coordinator mid-session is blocked" {
    jq 'del(.hooks.Stop[0])' "$SETTINGS" >"$NEW"
    run change
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
    assert_contains "Stop coordinator" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "making the coordinator async counts as removing it" {
    jq '(.hooks.Stop[0].hooks[0].async) = true' "$SETTINGS" >"$NEW"
    run change
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
}

@test "removing the merge trigger or the question gate is blocked" {
    jq '.hooks.PostToolUse |= map(select(any(.hooks[]; .command | endswith("gh_monitor_trigger.sh")) | not))' "$SETTINGS" >"$NEW"
    run change
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
    jq '.hooks.PreToolUse |= map(select(any(.hooks[]; .command | endswith("ask_gate.sh")) | not))' "$SETTINGS" >"$NEW"
    run change
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
}

@test "project settings and unreadable files are never blocked" {
    jq 'del(.hooks.Stop)' "$SETTINGS" >"$NEW"
    run change project_settings
    assert_eq "" "$output"
    printf '{broken' >"$NEW"
    run change
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "log mode only logs" {
    export DONE_GATE_MODE=log
    jq 'del(.hooks.Stop)' "$SETTINGS" >"$NEW"
    run change
    assert_eq "" "$output"
    assert_contains "would_block config change" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}
