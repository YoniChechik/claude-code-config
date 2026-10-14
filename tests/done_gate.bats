#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/done_gate.sh"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_CODE_SESSION_ID=s1
    LEDGER="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
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

predicate() {
    mkdir -p "${LEDGER%/*}"
    chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/sessions" "${LEDGER%/*}"
    printf '{"ts":"2026-10-14T09:00:00Z","kind":"predicate","items":%s,"sha256":"h1"}\n' "$1" >>"$LEDGER"
}

@test "check runs a cmd: item and records a passing check bound to the predicate hash" {
    predicate '["cmd:echo pong","merged:o/r#1"]'
    run bash "$SCRIPT" check 0
    assert_eq 0 "$status"
    assert_contains "pong" "$output"
    assert_contains "check 0: exit 0" "$output"
    assert_eq 0 "$(jq -rs 'map(select(.kind == "check"))[0].exit' "$LEDGER")"
    assert_eq h1 "$(jq -rs 'map(select(.kind == "check"))[0].pred_sha' "$LEDGER")"
}

@test "a failing cmd: item records its exit code and returns it" {
    predicate '["cmd:exit 4"]'
    run bash "$SCRIPT" check 0
    assert_eq 4 "$status"
    assert_eq 4 "$(jq -rs 'map(select(.kind == "check"))[0].exit' "$LEDGER")"
}

@test "a non-cmd item cannot be checked" {
    predicate '["merged:o/r#1"]'
    run bash "$SCRIPT" check 0
    assert_eq 1 "$status"
    assert_contains "is not a cmd: item" "$output"
}

@test "without a predicate check explains how to record one" {
    run bash "$SCRIPT" check 0
    assert_eq 1 "$status"
    assert_contains "/session-name <label> --done" "$output"
}

@test "status prints the ledger with readable timestamps" {
    predicate '["cmd:true"]'
    bash "$SCRIPT" check 0 >/dev/null
    run bash "$SCRIPT" status
    assert_contains "2026-10-14T09:00:00Z predicate" "$output"
    assert_contains " check " "$output"
}

@test "a missing session id or bad usage fails loudly" {
    run bash "$SCRIPT" nope
    assert_eq 2 "$status"
    CLAUDE_CODE_SESSION_ID="" run bash "$SCRIPT" status
    assert_eq 1 "$status"
}
