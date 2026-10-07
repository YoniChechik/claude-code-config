#!/usr/bin/env bats

LIB="${BATS_TEST_DIRNAME}/../scripts/_hook_log.sh"

setup() {
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export HOOK_NAME="test_hook"
    LOG="$CLAUDE_HOOK_LOG_DIR/hooks.log"
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in (*"$1"*)
        printf 'expected NOT to contain: %s\nactual: %s\n' "$1" "$2" >&2
        return 1
    ;; esac
    return 0
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

log_one() {
    bash -c 'source "$1"; hook_log "$2" "$3"' _ "$LIB" "$1" "$2"
}

redacted() {
    bash -c 'source "$1"; hook_redact "$2"; printf "%s" "$REPLY"' _ "$LIB" "$1"
}

@test "line format is timestamp, hook name with pid, reason, then the command" {
    log_one "skip: no candidate" "gh pr view 1"
    run cat "$LOG"
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\ test_hook\[[0-9]+\]\ skip:\ no\ candidate\ \|\ gh\ pr\ view\ 1$ ]]
}

@test "the log command defaults to HOOK_LOG_CMD" {
    HOOK_LOG_CMD="git push origin x" bash -c 'source "$1"; hook_log "r"' _ "$LIB"
    run cat "$LOG"
    assert_contains "| git push origin x" "$output"
}

@test "newlines, tabs and carriage returns are escaped so every entry is one line" {
    log_one $'multi\nline reason' $'a\nb\tc\rd'
    run wc -l <"$LOG"
    assert_eq 1 "$(tr -d ' ' <<<"$output")"
    run cat "$LOG"
    assert_contains 'multi\nline reason' "$output"
    assert_contains 'a\nb\tc\rd' "$output"
}

@test "the logged command is capped at 160 characters after redaction" {
    long=$(printf 'x%.0s' {1..400})
    log_one r "echo $long"
    run cat "$LOG"
    cmd_part=${output#*| }
    assert_eq 160 "${#cmd_part}"
}

@test "a secret straddling the cap is redacted before the cap is applied" {
    pad=$(printf 'p%.0s' {1..150})
    log_one r "echo $pad GH_TOKEN=abcdefghijklmnopqrstuvwxyz"
    run cat "$LOG"
    assert_not_contains "abcdefghij" "$output"
}

@test "redacts Authorization header values" {
    run redacted 'curl -H "Authorization: Bearer abc.def-123" https://x'
    assert_eq 'curl -H "Authorization: Bearer ***" https://x' "$output"
    run redacted "curl -H 'authorization: token sekrit' https://x"
    assert_eq "curl -H 'authorization: token ***' https://x" "$output"
}

@test "redacts bearer tokens outside an Authorization header" {
    run redacted 'http GET x Bearer:x bearer qwerty123'
    assert_eq 'http GET x Bearer:x bearer ***' "$output"
}

@test "redacts KEY=value style secrets but keeps the name" {
    run redacted 'GH_TOKEN=abc123 OPENAI_API_KEY=sk_live_1 DB_PASSWORD=hunter2 gh pr merge 1'
    assert_eq 'GH_TOKEN=*** OPENAI_API_KEY=*** DB_PASSWORD=*** gh pr merge 1' "$output"
}

@test "redacts --token style flags in both forms" {
    run redacted 'tool --token=abc --password hunter2 --api-key k1 run'
    assert_eq 'tool --token=*** --password *** --api-key *** run' "$output"
}

@test "redacts JSON secret fields" {
    run redacted '{"password": "hunter2", "user": "x"}'
    assert_eq '{"password": "***", "user": "x"}' "$output"
}

@test "redacts well-known token prefixes" {
    run redacted 'echo ghp_ABCDEFGHIJKLMNOPQRSTUV123456 github_pat_11ABCDEFGHIJKLMNOPQRSTUV_xyz sk-proj-abcdefghijklmnop1234 xoxb-1234567890-abc AKIAABCDEFGHIJKLMNOP glpat-abcdefghijklmnopqrst'
    assert_eq 'echo *** *** *** *** *** ***' "$output"
}

@test "redacts JWTs" {
    run redacted 'x eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_part-1 y'
    assert_eq 'x *** y' "$output"
}

@test "redacts long hex strings" {
    run redacted 'git show 0123456789abcdef0123456789abcdef01234567 --stat'
    assert_eq 'git show *** --stat' "$output"
}

@test "redacts long mixed-case base64-like runs" {
    run redacted 'key aB3dEfGh1jKlMnOpQrStUvWxYz012345678+= end'
    assert_eq 'key *** end' "$output"
}

@test "keeps ordinary long words, paths, short SHAs and author flags" {
    cmd='git log --author=Yoni abc1234 /Users/someone/core/app-backend/hardcoded_texts/skills feat-bashparse-hook-library-something-long'
    run redacted "$cmd"
    assert_eq "$cmd" "$output"
}

@test "the log directory is 0700 and the log file is 0600" {
    log_one r c
    run stat -f %Lp "$CLAUDE_HOOK_LOG_DIR"
    assert_eq 700 "$output"
    run stat -f %Lp "$LOG"
    assert_eq 600 "$output"
}

@test "rotates to hooks.log.1 once the size cap is exceeded, keeping 0600" {
    export CLAUDE_HOOK_LOG_MAX_BYTES=150 CLAUDE_HOOK_LOG_CHECK_EVERY=1
    for i in 1 2 3 4 5 6; do log_one "entry $i" "echo $i"; done
    run cat "$LOG.1"
    assert_contains "entry 1" "$output"
    run cat "$LOG"
    assert_contains "entry 6" "$output"
    assert_not_contains "entry 1 " "$output"
    run stat -f %Lp "$LOG"
    assert_eq 600 "$output"
}

@test "concurrent writers never interleave or lose lines" {
    for w in $(seq 1 16); do
        bash -c 'source "$1"; for i in $(seq 1 40); do hook_log "writer $2 line $i" "echo $2 $i"; done' _ "$LIB" "$w" &
    done
    wait
    run wc -l <"$LOG"
    assert_eq 640 "$(tr -d ' ' <<<"$output")"
    run grep -cvE '^[0-9T:-]+ test_hook\[[0-9]+\] writer [0-9]+ line [0-9]+ \| echo [0-9]+ [0-9]+$' "$LOG"
    assert_eq 0 "$output"
}

@test "skip logs the reason and exits 0" {
    run bash -c 'source "$1"; skip "not a candidate"; echo unreachable' _ "$LIB"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$LOG"
    assert_contains "skip: not a candidate" "$output"
}

@test "fail_closed logs and emits a PreToolUse ask decision" {
    run bash -c 'source "$1"; fail_closed "parser failed"; echo unreachable' _ "$LIB"
    assert_eq 0 "$status"
    assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")"
    assert_eq PreToolUse "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")"
    assert_contains "parser failed" "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")"
    run cat "$LOG"
    assert_contains "fail_closed: parser failed" "$output"
}

@test "an unwritable log directory never fails the hook" {
    export CLAUDE_HOOK_LOG_DIR=/dev/null/nope
    run bash -c 'source "$1"; hook_log r c; echo after' _ "$LIB"
    assert_eq 0 "$status"
    assert_eq after "$output"
}
