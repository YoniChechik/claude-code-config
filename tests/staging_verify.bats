#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/staging_verify.sh"
SHA=abcdef1234567890abcdef1234567890abcdef12
PARENT=1111111222222233333334444444555555566666

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_CODE_SESSION_ID=s1
    export STAGING_VERIFY_POLL=0
    LEDGER="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB" "$BATS_TEST_TMPDIR/bin"
    export STUB
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB/gh_calls.log"
case "$2" in
    */commits/*) cat "$STUB/parent" 2>/dev/null; exit "$(cat "$STUB/parent_rc" 2>/dev/null || echo 0)" ;;
    */contents/*)
        if [ -f "$STUB/config" ]; then base64 <"$STUB/config"; exit 0; fi
        echo 'gh: Not Found (HTTP 404)'
        exit 1
        ;;
esac
exit 99
GH
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/bin/bash
n=$(cat "$STUB/curl_n" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" >"$STUB/curl_n"
f="$STUB/curl.$n"
[ -f "$f" ] || f="$STUB/curl"
cat "$f"
CURL
    chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    printf '%s\n' "$PARENT" >"$STUB/parent"
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

config() { printf '%s' "$1" >"$STUB/config"; }

verify() { run bash "$SCRIPT" o/r 4016 4016 "$SHA" "${1:-pass}"; }

field() { jq -r "$1" "$LEDGER"; }

@test "the config is read from the merge commit's first parent, never from the merge itself" {
    config '{"targets":[]}'
    verify
    assert_contains "api repos/o/r/commits/$SHA --jq .parents[0].sha" "$(cat "$STUB/gh_calls.log")"
    assert_contains "api repos/o/r/contents/.claude/verify.json?ref=$PARENT --jq .content" "$(cat "$STUB/gh_calls.log")"
}

@test "a missing verify.json on the base branch records no-config" {
    verify
    assert_eq 0 "$status"
    assert_contains "Staging verify NOT CONFIGURED for o/r" "$output"
    assert_eq no-config "$(field .result)"
    assert_eq verify "$(field .kind)"
    assert_eq 4016 "$(field .target)"
}

@test "targets: [] on the base branch records n/a with its reason" {
    config '{"targets":[],"reason":"library repo, nothing deploys"}'
    verify
    assert_contains "Staging verify N/A for o/r: library repo, nothing deploys" "$output"
    assert_eq n/a "$(field .result)"
    [[ $(field .config_sha) =~ ^[0-9a-f]{64}$ ]]
}

@test "staging serving the merge SHA plus passing probes records pass with observed sha and probe evidence" {
    config '{"targets":[{"name":"staging","sha_url":"https://stg/version","sha_jq":".sha","probes":[{"cmd":"echo pong","expect":"pong"}]}]}'
    printf '{"sha":"%s"}' "${SHA:0:12}" >"$STUB/curl"
    verify
    assert_contains "Staging verify PASSED for o/r (merge commit $SHA): staging serves ${SHA:0:12}, 1/1 probes ok" "$output"
    assert_eq pass "$(field .result)"
    assert_eq "${SHA:0:12}" "$(field '.targets[0].observed_sha')"
    assert_eq 0 "$(field '.targets[0].probes[0].exit')"
    assert_eq true "$(field '.targets[0].probes[0].matched')"
    assert_eq pong "$(field '.targets[0].probes[0].out_head')"
}

@test "the watcher polls until staging serves the merge SHA" {
    config '{"targets":[{"name":"staging","sha_url":"https://stg/version","timeout_s":30}]}'
    printf '{"sha":"0000000old"}' >"$STUB/curl.1"
    printf '{"sha":"%s"}' "$SHA" >"$STUB/curl"
    verify
    assert_eq pass "$(field .result)"
    assert_eq 2 "$(cat "$STUB/curl_n")"
}

@test "staging still serving an old SHA at the timeout records fail" {
    config '{"targets":[{"name":"staging","sha_url":"https://stg/version","timeout_s":0}]}'
    printf '{"sha":"0000000old"}' >"$STUB/curl"
    verify
    assert_contains "Staging verify FAILED" "$output"
    assert_contains "serves '0000000old', not ${SHA:0:12}" "$output"
    assert_eq fail "$(field .result)"
}

@test "a probe whose output lacks the expected text records fail even with exit 0" {
    config '{"targets":[{"name":"staging","sha_url":"https://stg/version","probes":[{"cmd":"echo nope","expect":"pong"}]}]}'
    printf '{"sha":"%s"}' "$SHA" >"$STUB/curl"
    verify
    assert_eq fail "$(field .result)"
    assert_eq false "$(field '.targets[0].probes[0].matched')"
    assert_contains 'expected "pong"' "$output"
}

@test "a failing probe records its exit code" {
    config '{"targets":[{"name":"staging","sha_url":"https://stg/version","probes":[{"cmd":"exit 3"}]}]}'
    printf '{"sha":"%s"}' "$SHA" >"$STUB/curl"
    verify
    assert_eq fail "$(field .result)"
    assert_eq 3 "$(field '.targets[0].probes[0].exit')"
}

@test "a target without sha_url cannot pass" {
    config '{"targets":[{"name":"staging","probes":[]}]}'
    verify
    assert_eq fail "$(field .result)"
    assert_contains "no sha_url" "$output"
}

@test "a failed post-merge CI records fail without reading the config" {
    verify fail
    assert_eq fail "$(field .result)"
    assert_eq "post-merge CI fail" "$(field .reason)"
    [ ! -e "$STUB/gh_calls.log" ]
}

@test "an unreadable merge commit records error" {
    printf '1\n' >"$STUB/parent_rc"
    : >"$STUB/parent"
    verify
    assert_eq error "$(field .result)"
}

@test "an invalid verify.json records error" {
    config '{"nope":1}'
    verify
    assert_eq error "$(field .result)"
    assert_contains "no targets array" "$output"
}

@test "without a session id the verdict is printed and nothing is written" {
    unset CLAUDE_CODE_SESSION_ID
    config '{"targets":[]}'
    verify
    assert_contains "Staging verify N/A" "$output"
    [ ! -e "$LEDGER" ]
}
