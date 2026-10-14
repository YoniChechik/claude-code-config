#!/usr/bin/env bats

LIB="${BATS_TEST_DIRNAME}/../scripts/_state.sh"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    unset DONE_GATE_MODE
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

lib() { bash -c "source '$LIB'; $1"; }

@test "parallel ledger appends of large records never interleave" {
    lib 'state_init s1' || return 1
    local i
    for i in $(seq 1 24); do
        lib "state_init s1 && ledger_append \"\$(jq -nc --arg p \"\$(head -c 20000 /dev/zero | tr '\\0' $((i % 10)))\" --argjson i $i '{kind: \"check\", i: \$i, pad: \$p}')\"" &
    done
    wait
    local ledger="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    assert_eq 24 "$(wc -l <"$ledger" | tr -d ' ')"
    assert_eq 24 "$(jq -c . "$ledger" | wc -l | tr -d ' ')"
    assert_eq 600 "$(stat -f %Lp "$ledger")"
}

@test "ledger_latest returns the last record of a kind and ledger_has_kind finds a kind" {
    lib 'state_init s1 && ledger_append "{\"kind\":\"predicate\",\"sha256\":\"a\"}" && ledger_append "{\"kind\":\"merge\"}" && ledger_append "{\"kind\":\"predicate\",\"sha256\":\"b\"}"'
    assert_eq b "$(lib 'state_init s1 && ledger_latest predicate && jq -r .sha256 <<<"$REPLY"')"
    lib 'state_init s1 && ledger_has_kind merge'
    run lib 'state_init s1 && ledger_has_kind push'
    assert_eq 1 "$status"
}

@test "ledger_latest on a session with no ledger is empty, not an error" {
    run lib 'state_init s1 && ledger_latest predicate && printf "[%s]" "$REPLY"'
    assert_eq 0 "$status"
    assert_eq "[]" "$output"
}

@test "ledger_append refuses a symlinked ledger" {
    lib 'state_init s1'
    : >"$BATS_TEST_TMPDIR/other"
    ln -s "$BATS_TEST_TMPDIR/other" "$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    run lib 'state_init s1'
    assert_eq 1 "$status"
    run lib 'STATE_DIR="$CLAUDE_STATE_DIR/sessions/s1"; ledger_append "{\"kind\":\"x\"}"'
    assert_eq 1 "$status"
    [ ! -s "$BATS_TEST_TMPDIR/other" ]
}

@test "state_mode: env wins, an invalid env falls back to the mode file, garbage defaults to log" {
    lib 'state_init s1'
    assert_eq log "$(lib 'state_mode; echo $REPLY')"
    printf 'enforce\n' >"$CLAUDE_STATE_DIR/done_gate.mode"
    assert_eq enforce "$(lib 'state_mode; echo $REPLY')"
    assert_eq log "$(DONE_GATE_MODE=log lib 'state_mode; echo $REPLY')"
    run env DONE_GATE_MODE=yes bash -c "source '$LIB'; state_mode; echo \$REPLY"
    assert_eq enforce "${lines[-1]}"
    assert_contains "invalid DONE_GATE_MODE 'yes'" "$output"
    printf 'maybe\n' >"$CLAUDE_STATE_DIR/done_gate.mode"
    run lib 'state_mode; echo $REPLY'
    assert_eq log "${lines[-1]}"
    assert_contains "invalid mode 'maybe'" "$output"
}

@test "state_kill_switch honours DONE_GATE_KILL_TTL at the boundary" {
    lib 'state_init s1'
    mkdir -m 700 "$CLAUDE_STATE_DIR/override"
    touch -t "$(date -r $(($(date +%s) - 100)) +%Y%m%d%H%M.%S)" "$CLAUDE_STATE_DIR/override/done_gate.off"
    DONE_GATE_KILL_TTL=110 lib 'state_kill_switch'
    run env DONE_GATE_KILL_TTL=90 bash -c "source '$LIB'; state_kill_switch"
    assert_eq 1 "$status"
}

@test "state_write is atomic and refuses a non-regular target" {
    lib 'state_init s1'
    lib 'state_init s1 && state_write "$STATE_DIR/gate.json" "{}"'
    assert_eq "{}" "$(cat "$CLAUDE_STATE_DIR/sessions/s1/gate.json")"
    rm "$CLAUDE_STATE_DIR/sessions/s1/gate.json"
    mkdir "$CLAUDE_STATE_DIR/sessions/s1/gate.json"
    run lib 'STATE_DIR="$CLAUDE_STATE_DIR/sessions/s1"; state_write "$STATE_DIR/gate.json" "{}"'
    assert_eq 1 "$status"
    assert_eq 0 "$(find "$CLAUDE_STATE_DIR/sessions/s1" -name '.tmp.*' | wc -l | tr -d ' ')"
}
