#!/usr/bin/env bats
#
# Tests for the CI section of scripts/status_line.sh: one row per watcher of the
# session, plus the session-level "finished PRs" row.
#
# Strategy:
#   - The real script is run end to end, fed a hook payload on stdin, with every
#     /tmp path redirected into BATS_TEST_TMPDIR via CLAUDE_NOTIFY_TMP_DIR (which
#     _notify.sh honors and status_line.sh inherits by sourcing it).
#   - Watcher liveness uses a REAL alive process (exec -a ci_watch_fake sleep)
#     against a guaranteed-dead PID, so the ps/grep logic runs unmocked.
#   - Assertions run against the output with ANSI colour sequences stripped, so
#     they read as the user's text; the OSC 8 hyperlink targets are asserted on
#     the RAW output, because those ARE the feature.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does not
# fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

STATUS_LINE="${BATS_TEST_DIRNAME}/../scripts/status_line.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    SESSION="testsess"
    SPAWNED_PIDS_FILE="$BATS_TEST_TMPDIR/spawned_pids"
    : > "$SPAWNED_PIDS_FILE"
}

teardown() {
    while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$SPAWNED_PIDS_FILE"
    return 0
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

slot_for_branch() {
    printf '%s_%s-0123456789' "$SESSION" "$1"
}

# A live process whose argv contains "ci_watch", recorded in branch $1's
# lockfile so that slot renders as alive.
spawn_fake_watcher() {
    bash -c 'exec -a ci_watch_fake sleep 300' </dev/null >/dev/null 2>&1 3>&- &
    local pid=$!
    disown 2>/dev/null || true
    printf '%s\n' "$pid" >> "$SPAWNED_PIDS_FILE"
    printf '%s' "$pid" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch "$1")"
}

write_ci_state() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_$(slot_for_branch "$1")"
}

# PR cache for branch $1: number $2, url $3, optional merge commit oid $4.
write_pr_cache() {
    local oid_json='null'
    [ -n "${4:-}" ] && oid_json="{\"oid\":\"$4\"}"
    printf '{"url":"%s","number":%s,"state":"OPEN","mergeable":true,"mergeStateStatus":"CLEAN","mergeCommit":%s,"repoUrl":"https://github.com/o/r"}' \
        "$3" "$2" "$oid_json" \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_pr_$(slot_for_branch "$1")"
}

finished_file() {
    printf '%s/ci_watch_finished_%s' "$CLAUDE_NOTIFY_TMP_DIR" "$SESSION"
}

# Run status_line.sh with a payload naming this session. Sets $raw (bytes as
# emitted) and $plain (same, with ANSI SGR colour sequences stripped).
run_status_line() {
    local payload
    payload="{\"workspace\":{\"current_dir\":\"${BATS_TEST_TMPDIR}\"},\"session_id\":\"${SESSION}\"}"
    raw="$(printf '%s' "$payload" | bash "$STATUS_LINE")"
    # Strip SGR colour sequences AND the OSC 8 hyperlink wrappers (ESC ] 8 ; ;
    # <target> BEL), so $plain is the text a user actually reads. The wrappers
    # sit INSIDE a row, between "finished PRs: " and "#3009", so leaving them in
    # would break every contiguous-substring assertion.
    plain="$(printf '%s' "$raw" \
        | sed $'s/\033\\[[0-9;]*m//g' \
        | sed $'s/\033]8;;[^\a]*\a//g')"
    # The script traps ERR and prints this instead of the status line; it would
    # otherwise turn every content assertion into a silent false negative.
    assert_not_contains "(status error)" "$raw"
}

# ---------------------------------------------------------------------------
# One row per watcher
# ---------------------------------------------------------------------------

@test "no watchers: no PR row at all" {
    run_status_line
    assert_not_contains "PR #" "$plain"
    assert_not_contains "ci:" "$plain"
}

@test "one watcher: renders PR number and ci state on one row" {
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains "PR #3011 | ci: running" "$plain"
}

@test "one watcher: the PR number is an OSC 8 hyperlink to the PR" {
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains $'\033]8;;https://github.com/o/r/pull/3011\a' "$raw"
}

@test "three watchers: one row each, all rendered" {
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    write_ci_state "feat-b" "feat-b:passed"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012"
    write_ci_state "feat-c" "feat-c:failed"
    write_pr_cache "feat-c" 3013 "https://github.com/o/r/pull/3013"

    run_status_line
    assert_contains "PR #3011 | ci: running" "$plain"
    assert_contains "PR #3012 | ci: passed" "$plain"
    assert_contains "PR #3013 | ci: failed" "$plain"
    [ "$(printf '%s\n' "$plain" | grep -c 'PR #')" -eq 3 ]
}

@test "another session's watcher is never rendered" {
    printf 'x:running' > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_othersess_feat-z-0123456789"
    printf '{"url":"https://github.com/o/r/pull/999","number":999,"state":"OPEN","repoUrl":"https://github.com/o/r","mergeCommit":null}' \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_pr_othersess_feat-z-0123456789"
    run_status_line
    assert_not_contains "PR #999" "$plain"
}

@test "liveness is per-slot: a dead watcher's own row reports died" {
    # feat-a's watcher is dead; feat-b's is alive. Only feat-a's row degrades.
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    printf '999999' > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch feat-a)"
    write_ci_state "feat-b" "feat-b:running"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012"
    spawn_fake_watcher "feat-b"

    run_status_line
    assert_contains "PR #3011 | ⚠ ci watcher died" "$plain"
    assert_contains "PR #3012 | ci: running" "$plain"
}

@test "monitor-detached is reported per slot, with the state still parsed" {
    write_ci_state "feat-a" "feat-a:running:monitor-detached@1757000000"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains "ci notifications lost" "$plain"
}

# ---------------------------------------------------------------------------
# The post-merge label and its hyperlink
# ---------------------------------------------------------------------------

@test "merging: labelled 'post merge', not 'ci'" {
    write_ci_state "feat-b" "feat-b:merging"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012" "deadbeef"
    spawn_fake_watcher "feat-b"
    run_status_line
    assert_contains "PR #3012 | post merge: running" "$plain"
    assert_not_contains "PR #3012 | ci:" "$plain"
}

@test "merging: 'post merge' links to the merge commit's check list" {
    write_ci_state "feat-b" "feat-b:merging"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012" "deadbeef"
    spawn_fake_watcher "feat-b"
    run_status_line
    assert_contains $'\033]8;;https://github.com/o/r/commit/deadbeef/checks\a' "$raw"
}

@test "merged-failed: labelled 'post merge' and linked too" {
    write_ci_state "feat-b" "feat-b:merged-failed"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012" "deadbeef"
    run_status_line
    assert_contains "PR #3012 | post merge: failed" "$plain"
    assert_contains $'\033]8;;https://github.com/o/r/commit/deadbeef/checks\a' "$raw"
}

@test "post merge stays readable when the merge commit is not cached yet" {
    write_ci_state "feat-b" "feat-b:merging"
    write_pr_cache "feat-b" 3012 "https://github.com/o/r/pull/3012"
    spawn_fake_watcher "feat-b"
    run_status_line
    assert_contains "PR #3012 | post merge: running" "$plain"
}

@test "merged-passed renders NO row of its own" {
    # The PR has moved to the finished-PRs row; keeping a row here would show it
    # twice.
    write_ci_state "feat-c" "feat-c:merged-passed"
    write_pr_cache "feat-c" 3013 "https://github.com/o/r/pull/3013" "cafebabe"
    run_status_line
    assert_not_contains "PR #3013" "$plain"
}

# ---------------------------------------------------------------------------
# The session-level finished-PRs row
# ---------------------------------------------------------------------------

@test "finished PRs: omitted when the file does not exist" {
    run_status_line
    assert_not_contains "finished PRs" "$plain"
}

@test "finished PRs: omitted when the file is empty" {
    : > "$(finished_file)"
    run_status_line
    assert_not_contains "finished PRs" "$plain"
}

@test "finished PRs: omitted when every line fails to parse" {
    {
        printf '%s\n' 'not json at all'
        printf '%s\n' '{"number": 1, "url":'
    } > "$(finished_file)"
    run_status_line
    assert_not_contains "finished PRs" "$plain"
}

@test "finished PRs: one entry renders as a hyperlinked number" {
    printf '%s\n' '{"number": 3009, "url": "https://github.com/o/r/pull/3009", "ts": 100.5}' \
        > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3009" "$plain"
    assert_contains $'\033]8;;https://github.com/o/r/pull/3009\a' "$raw"
}

@test "finished PRs: newest ts first, whatever order the file holds" {
    # Watchers append as they finish; the file's own order is arrival order and
    # can be anything. Ordering is the renderer's job.
    {
        printf '%s\n' '{"number": 1, "url": "u1", "ts": 100}'
        printf '%s\n' '{"number": 3, "url": "u3", "ts": 300}'
        printf '%s\n' '{"number": 2, "url": "u2", "ts": 200}'
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3, #2, #1" "$plain"
}

@test "finished PRs: a torn line is SKIPPED, the good ones still render" {
    # A watcher killed mid-append can leave a half-written line. Aborting on it
    # would hide every finished PR of the session.
    {
        printf '%s\n' '{"number": 1, "url": "u1", "ts": 100}'
        printf '%s\n' '{"number": 2, "url": "u2", "t'
        printf '%s\n' '{"number": 3, "url": "u3", "ts": 300}'
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3, #1" "$plain"
    assert_not_contains "#2" "$plain"
}

@test "finished PRs: a duplicate PR number is collapsed, keeping the newest" {
    # Relaunching a watcher on an already-finished PR appends a second line by
    # design — dedup is the renderer's job, not the writer's.
    {
        printf '%s\n' '{"number": 7, "url": "old-url", "ts": 100}'
        printf '%s\n' '{"number": 7, "url": "new-url", "ts": 500}'
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #7" "$plain"
    [ "$(printf '%s\n' "$plain" | grep -c '#7')" -eq 1 ]
    assert_contains "new-url" "$raw"
    assert_not_contains "old-url" "$raw"
}

@test "finished PRs: an entry with a missing field is skipped, not rendered blank" {
    {
        printf '%s\n' '{"number": 1, "url": "u1"}'
        printf '%s\n' '{"url": "u2", "ts": 200}'
        printf '%s\n' '{"number": 3, "url": "u3", "ts": 300}'
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3" "$plain"
    [ "$(printf '%s\n' "$plain" | grep -c 'finished PRs')" -eq 1 ]
    assert_not_contains "#1" "$plain"
}

@test "finished PRs: renders below the per-watcher rows" {
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    printf '%s\n' '{"number": 3009, "url": "u9", "ts": 100}' > "$(finished_file)"

    run_status_line
    local pr_row finished_row
    pr_row="$(printf '%s\n' "$plain" | grep -n 'PR #3011' | cut -d: -f1)"
    finished_row="$(printf '%s\n' "$plain" | grep -n 'finished PRs' | cut -d: -f1)"
    [ -n "$pr_row" ]
    [ -n "$finished_row" ]
    [ "$finished_row" -gt "$pr_row" ]
}

@test "finished PRs: another session's finished file is never read" {
    printf '%s\n' '{"number": 999, "url": "u999", "ts": 100}' \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_finished_othersess"
    run_status_line
    assert_not_contains "finished PRs" "$plain"
}
