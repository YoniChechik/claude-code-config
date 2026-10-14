#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/staging_verify.sh"
SHA=abcdef1234567890abcdef1234567890abcdef12

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export CLAUDE_VERIFY_DIR="$BATS_TEST_TMPDIR/verify"
    export CLAUDE_CODE_SESSION_ID=s1
    export STAGING_VERIFY_POLL=0
    LEDGER="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB" "$BATS_TEST_TMPDIR/bin" "$CLAUDE_VERIFY_DIR"
    export STUB
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB/gh_calls.log"
case "$*" in
    "api repos/o/r/compare/"*"--jq .status") cat "$STUB/compare" 2>/dev/null || echo diverged; exit 0 ;;
esac
exit 99
GH
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB/curl_calls.log"
[[ " $* " == *" --proto =https --proto-redir =https "* ]] || exit 97
out=""
while (($#)); do
    case "$1" in
        -o) out=$2; shift ;;
    esac
    shift
done
if [ -n "$out" ]; then
    cat "$STUB/probe_body" >"$out" 2>/dev/null
    printf '%s' "$(cat "$STUB/probe_status" 2>/dev/null || echo 200)"
    exit "$(cat "$STUB/probe_rc" 2>/dev/null || echo 0)"
fi
n=$(cat "$STUB/curl_n" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" >"$STUB/curl_n"
f="$STUB/curl.$n"
[ -f "$f" ] || f="$STUB/curl"
cat "$f"
CURL
    chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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

config() { printf '%s' "$1" >"$CLAUDE_VERIFY_DIR/o__r.json"; }

serve_sha() { printf '{"sha":"%s"}' "$1" >"$STUB/curl"; }

verify() { run bash "$SCRIPT" o/r 4016 4016 "$SHA" "${1:-pass}"; }

field() { jq -r "$1" "$LEDGER"; }

STG='"name":"staging","sha_url":"https://stg/version","sha_jq":".sha"'

@test "the config is read only from the local verify dir, never from the repository" {
    config '{"targets":[]}'
    verify
    assert_eq 0 "$status"
    assert_eq n/a "$(field .result)"
    [ ! -e "$STUB/gh_calls.log" ]
}

@test "a missing local verify config records no-config with its path" {
    verify
    assert_eq 0 "$status"
    assert_contains "Staging verify NOT CONFIGURED for o/r" "$output"
    assert_contains "$CLAUDE_VERIFY_DIR/o__r.json" "$output"
    assert_eq no-config "$(field .result)"
    assert_eq verify "$(field .kind)"
    assert_eq 4016 "$(field .target)"
    assert_eq 4016 "$(field .pr)"
}

@test "a symlinked verify config is untrusted" {
    printf '{"targets":[]}' >"$BATS_TEST_TMPDIR/elsewhere.json"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.json" "$CLAUDE_VERIFY_DIR/o__r.json"
    verify
    assert_eq error "$(field .result)"
    assert_contains "untrusted verify config: symlink" "$output"
}

@test "targets: [] records n/a with its reason" {
    config '{"targets":[],"reason":"library repo, nothing deploys"}'
    verify
    assert_contains "Staging verify N/A for o/r: library repo, nothing deploys" "$output"
    assert_eq n/a "$(field .result)"
    [[ $(field .config_sha) =~ ^[0-9a-f]{64}$ ]]
}

@test "staging serving the merge SHA plus passing probes records pass with observed sha and probe evidence" {
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"https://stg/ping\",\"expect\":\"pong\"}]}]}"
    serve_sha "${SHA:0:12}"
    printf 'pong' >"$STUB/probe_body"
    verify
    assert_contains "Staging verify PASSED for o/r (merge commit $SHA): staging serves ${SHA:0:12}, 1/1 probes ok" "$output"
    assert_eq pass "$(field .result)"
    assert_eq "${SHA:0:12}" "$(field '.targets[0].observed_sha')"
    assert_eq true "$(field '.targets[0].contains_merge')"
    assert_eq 0 "$(field '.targets[0].probes[0].exit')"
    assert_eq 200 "$(field '.targets[0].probes[0].status')"
    assert_eq true "$(field '.targets[0].probes[0].matched')"
    assert_eq pong "$(field '.targets[0].probes[0].out_head')"
    assert_eq https://stg/ping "$(field '.targets[0].probes[0].url')"
}

@test "every curl call is https-only with a timeout" {
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"https://stg/ping\"}]}]}"
    serve_sha "$SHA"
    verify
    assert_eq pass "$(field .result)"
    run cat "$STUB/curl_calls.log"
    assert_eq 2 "${#lines[@]}"
    assert_contains "--proto =https --proto-redir =https -sS -f --max-time 20 -- https://stg/version" "${lines[0]}"
    assert_contains "--proto =https --proto-redir =https -sS --max-time 60 -o" "${lines[1]}"
    assert_contains "-- https://stg/ping" "${lines[1]}"
}

@test "shell probes are rejected and never run" {
    config "{\"targets\":[{$STG,\"probes\":[{\"cmd\":\"touch $BATS_TEST_TMPDIR/pwned\"}]}]}"
    serve_sha "$SHA"
    verify
    assert_eq error "$(field .result)"
    assert_contains "shell probes are not supported" "$output"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ ! -e "$STUB/curl_calls.log" ]
}

@test "non-https sha_url and probe urls are rejected" {
    config '{"targets":[{"name":"a","sha_url":"file:///etc/passwd"}]}'
    verify
    assert_eq error "$(field .result)"
    assert_contains "sha_url must be an https:// URL" "$output"
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"http://stg/ping\"}]}]}"
    verify
    assert_contains "url must be an https:// URL" "$output"
    [ ! -e "$STUB/curl_calls.log" ]
}

@test "the watcher polls until staging serves the merge SHA" {
    config "{\"targets\":[{$STG,\"timeout_s\":30}]}"
    printf '{"sha":"0000000old"}' >"$STUB/curl.1"
    serve_sha "$SHA"
    verify
    assert_eq pass "$(field .result)"
    assert_eq 2 "$(cat "$STUB/curl_n")"
}

@test "staging serving a descendant of the merge commit passes" {
    config "{\"targets\":[{$STG,\"timeout_s\":0}]}"
    serve_sha 0123456789abcdef
    printf 'ahead\n' >"$STUB/compare"
    verify
    assert_eq pass "$(field .result)"
    assert_eq true "$(field '.targets[0].contains_merge')"
    assert_contains "api repos/o/r/compare/$SHA...0123456789abcdef --jq .status" "$(cat "$STUB/gh_calls.log")"
}

@test "staging still serving an old SHA at the timeout records fail" {
    config "{\"targets\":[{$STG,\"timeout_s\":0}]}"
    serve_sha 0000000a1d
    verify
    assert_contains "Staging verify FAILED" "$output"
    assert_contains "serves '0000000a1d', which does not contain ${SHA:0:12}" "$output"
    assert_eq fail "$(field .result)"
    assert_eq false "$(field '.targets[0].contains_merge')"
}

@test "an empty or null observed SHA never passes" {
    config "{\"targets\":[{$STG,\"timeout_s\":0}]}"
    printf '{"sha":null}' >"$STUB/curl"
    verify
    assert_eq fail "$(field .result)"
    assert_contains "serves 'nothing'" "$output"
    [ ! -e "$STUB/gh_calls.log" ]
}

@test "a probe whose body lacks the expected text records fail even with HTTP 200" {
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"https://stg/ping\",\"expect\":\"pong\"}]}]}"
    serve_sha "$SHA"
    printf 'nope' >"$STUB/probe_body"
    verify
    assert_eq fail "$(field .result)"
    assert_eq false "$(field '.targets[0].probes[0].matched')"
    assert_contains 'expected "pong"' "$output"
}

@test "a probe with an unexpected HTTP status records fail" {
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"https://stg/ping\"}]}]}"
    serve_sha "$SHA"
    printf '503' >"$STUB/probe_status"
    verify
    assert_eq fail "$(field .result)"
    assert_contains "expected HTTP 200" "$output"
}

@test "a probe that curl cannot reach records its curl exit code" {
    config "{\"targets\":[{$STG,\"probes\":[{\"url\":\"https://stg/ping\"}]}]}"
    serve_sha "$SHA"
    printf '7' >"$STUB/probe_rc"
    printf '000' >"$STUB/probe_status"
    verify
    assert_eq fail "$(field .result)"
    assert_eq 7 "$(field '.targets[0].probes[0].exit')"
}

@test "one failing target out of two fails the whole verify and records both" {
    config "{\"targets\":[{$STG},{\"name\":\"b\",\"sha_url\":\"https://b/version\",\"timeout_s\":0}]}"
    printf '{"sha":"%s"}' "$SHA" >"$STUB/curl.1"
    printf '{"sha":"0000000a1d"}' >"$STUB/curl"
    verify
    assert_eq fail "$(field .result)"
    assert_eq 2 "$(field '.targets | length')"
    assert_eq true "$(field '.targets[0].contains_merge')"
    assert_eq false "$(field '.targets[1].contains_merge')"
}

@test "a failed post-merge CI records fail without reading the config" {
    config '{"targets":[]}'
    verify fail
    assert_eq fail "$(field .result)"
    assert_eq "post-merge CI fail" "$(field .reason)"
}

@test "an invalid verify config records error" {
    config '{"nope":1}'
    verify
    assert_eq error "$(field .result)"
    assert_contains "no targets array" "$output"
    config 'not json'
    verify
    assert_contains "is not valid JSON" "$output"
}

@test "an invalid repo or merge sha records error before any lookup" {
    run bash "$SCRIPT" "../x" 1 1 "$SHA" pass
    assert_contains "invalid repository name" "$output"
    run bash "$SCRIPT" o/r 1 1 "not-a-sha" pass
    assert_contains "invalid merge commit" "$output"
}

@test "without a session id the verdict is printed and nothing is written" {
    unset CLAUDE_CODE_SESSION_ID
    config '{"targets":[]}'
    verify
    assert_contains "Staging verify N/A" "$output"
    [ ! -e "$LEDGER" ]
}
