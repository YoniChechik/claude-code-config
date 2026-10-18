#!/usr/bin/env bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"

setup() {
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    PROJECTS="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$PROJECTS/-Users-me-app"
    T="$PROJECTS/-Users-me-app/0123456789abcdef.jsonl"
    {
        jq -nc '{type: "user", entrypoint: "cli", timestamp: "2026-10-01T10:00:00Z", message: {content: "fix the login bug"}}'
        jq -nc '{type: "assistant", timestamp: "2026-10-01T10:05:00Z", message: {content: [{type: "text", text: "Fixed it. Should I merge PR #12?"}]}}'
        printf '{broken line\n'
        jq -nc '{type: "user", entrypoint: "cli", timestamp: "2026-10-01T10:06:00Z", message: {content: "continue"}}'
        jq -nc '{type: "assistant", isSidechain: true, timestamp: "2026-10-01T10:07:00Z", message: {content: [{type: "text", text: "subagent text"}]}}'
        jq -nc '{type: "assistant", timestamp: "2026-10-01T10:08:00Z", message: {content: [{type: "text", text: "Merged.\n\nSTATUS: COMPLETE gh pr view 12 shows MERGED"}]}}'
    } >"$T"
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

@test "nudge_report counts the continue nudge, the STATUS line and the skipped bad line" {
    run uv run --quiet "$SCRIPTS/nudge_report.py" --since 2026-09-01 --projects-dir "$PROJECTS" --json
    assert_eq 0 "$status"
    assert_eq 1 "$(jq -r .sessions <<<"$output")"
    assert_eq 1 "$(jq -r .nudges_total <<<"$output")"
    assert_eq 1 "$(jq -r '.by_category.continue' <<<"$output")"
    assert_eq 1 "$(jq -r '.unparseable_lines' <<<"$output")"
    assert_eq 1 "$(jq -r '.final_messages.with_status_line' <<<"$output")"
}

@test "nudge_report counts FAILURE verdicts and flags only the trivial ladder" {
    L="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    mkdir -p "$(dirname "$L")"
    {
        jq -nc '{kind: "failure", what: "deploy the api", accepted: true, exempt: null, failed_seen: 3, reason: null, n_attempts: 3, n_approaches: 2, ts: 1790000000,
            attempts: [{cmd: "gh run view 1", bin: "gh", exit: 1}, {cmd: "gh run rerun 1", bin: "gh", exit: 1}, {cmd: "gcloud run deploy api", bin: "gcloud", exit: 1}]}'
        printf '{broken line\n'
        jq -nc '{kind: "verify", ts: 1790000000}'
        jq -nc '{kind: "failure", what: "read the config", accepted: false, exempt: null, capped: true, failed_seen: 3, reason: null, n_attempts: 3, n_approaches: 2, ts: "2026-10-01T12:00:00Z",
            attempts: [range(3) | {cmd: "ls /missing", bin: "ls", exit: 1, out_excerpt: "ls: /missing: No such file or directory"}]}'
        jq -nc '{kind: "failure", what: "too old", accepted: true, exempt: null, failed_seen: 1, reason: null, n_attempts: 1, n_approaches: 1, ts: 1700000000, attempts: []}'
    } >"$L"
    run uv run --quiet "$SCRIPTS/nudge_report.py" --since 2026-09-01 --projects-dir "$PROJECTS" --json
    assert_eq 0 "$status"
    assert_eq 2 "$(jq -r '.failures.total' <<<"$output")"
    assert_eq 1 "$(jq -r '.failures.by_verdict.accepted' <<<"$output")"
    assert_eq 1 "$(jq -r '.failures.by_verdict.capped' <<<"$output")"
    assert_eq 1 "$(jq -r '.unparseable_ledger_lines' <<<"$output")"
    assert_eq 1 "$(jq -r '.trivial_ladders | length' <<<"$output")"
    assert_eq "s1" "$(jq -r '.trivial_ladders[0].session' <<<"$output")"
    assert_eq "read the config" "$(jq -r '.trivial_ladders[0].what' <<<"$output")"
    assert_contains "a: one cmd repeated 3x" "$(jq -r '.trivial_ladders[0].reason' <<<"$output")"
    assert_contains "b: every attempt is a missing-path probe" "$(jq -r '.trivial_ladders[0].reason' <<<"$output")"
    assert_contains "c: 1 distinct cmds / 1 distinct bins" "$(jq -r '.trivial_ladders[0].reason' <<<"$output")"

    run uv run --quiet "$SCRIPTS/nudge_report.py" --since 2026-09-01 --projects-dir "$PROJECTS"
    assert_eq 0 "$status"
    assert_contains "FAILURE ladders:" "$output"
    assert_contains "Trivial ladders: 1" "$output"
    assert_contains "cmds: ls /missing | ls /missing | ls /missing" "$output"
}

@test "nudge_report rejects a bad --since" {
    run uv run --quiet "$SCRIPTS/nudge_report.py" --since yesterday --projects-dir "$PROJECTS"
    assert_eq 2 "$status"
    assert_contains "invalid --since" "$output"
}

@test "done_gate_replay replays each final message through the gate and counts would-block verdicts" {
    run uv run --quiet "$SCRIPTS/done_gate_replay.py" --days 400 --projects-dir "$PROJECTS"
    assert_eq 0 "$status"
    assert_contains "Replayed 2 final messages from 1 transcripts" "$output"
    assert_contains "Unparseable transcript lines skipped: 1" "$output"
    assert_contains "Would block: 1 (50.0%)   would pass: 1" "$output"
    assert_contains "G1: 1 (50.0%)" "$output"
    assert_contains "Should I merge PR #12?" "$output"
}
