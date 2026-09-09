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
    # Long enough to outlive the test, short enough that a bats run killed
    # before teardown does not leave a process around for five minutes.
    bash -c 'exec -a ci_watch_fake sleep 30' </dev/null >/dev/null 2>&1 3>&- &
    local pid=$!
    disown 2>/dev/null || true
    printf '%s\n' "$pid" >> "$SPAWNED_PIDS_FILE"
    printf '%s' "$pid" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch "$1")"
}

write_ci_state() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_$(slot_for_branch "$1")"
}

# PR cache for branch $1: number $2, url $3, optional merge commit oid $4,
# optional mergeStateStatus $5 (default CLEAN).
write_pr_cache() {
    local oid_json='null'
    [ -n "${4:-}" ] && oid_json="{\"oid\":\"$4\"}"
    printf '{"url":"%s","number":%s,"state":"OPEN","mergeable":true,"mergeStateStatus":"%s","mergeCommit":%s,"repoUrl":"https://github.com/o/r"}' \
        "$3" "$2" "${5:-CLEAN}" "$oid_json" \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_pr_$(slot_for_branch "$1")"
}

finished_file() {
    printf '%s/ci_watch_finished_%s' "$CLAUDE_NOTIFY_TMP_DIR" "$SESSION"
}

# One finished-PR record: number $1, ts $2, url $3, repo $4 (default "o/r").
finished_line() {
    printf '{"number": %s, "repo": "%s", "url": "%s", "ts": %s}\n' \
        "$1" "${4:-o/r}" "$3" "$2"
}

# Run status_line.sh with a payload naming this session, under the bash in $1
# (default: whatever is on PATH). Sets $raw (bytes as emitted) and $plain (same,
# with ANSI SGR colour sequences stripped).
run_status_line() {
    local payload shell="${1:-bash}" rc=0
    payload="{\"workspace\":{\"current_dir\":\"${BATS_TEST_TMPDIR}\"},\"session_id\":\"${SESSION}\"}"
    raw="$(printf '%s' "$payload" | "$shell" "$STATUS_LINE")" || rc=$?
    # The script must EXIT clean too. Content assertions alone would pass on a
    # run that produced the right text and then died.
    if [ "$rc" -ne 0 ]; then
        printf 'status_line.sh exited %s\noutput: %s\n' "$rc" "$raw" >&2
        return 1
    fi
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
    finished_line 3009 100.5 "https://github.com/o/r/pull/3009" > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3009" "$plain"
    assert_contains $'\033]8;;https://github.com/o/r/pull/3009\a' "$raw"
}

@test "finished PRs: newest ts first, whatever order the file holds" {
    # Watchers append as they finish; the file's own order is arrival order and
    # can be anything. Ordering is the renderer's job.
    {
        finished_line 1 100 "u1"
        finished_line 3 300 "u3"
        finished_line 2 200 "u2"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3, #2, #1" "$plain"
}

@test "finished PRs: two entries sharing a ts still have a defined order" {
    # time.time() collisions are unlikely but possible for two watchers that
    # finish in the same tick. Without the PR-number tiebreak the row order
    # would be whatever sort happens to do.
    {
        finished_line 5 200 "u5"
        finished_line 9 200 "u9"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #5, #9" "$plain"
}

@test "finished PRs: a torn line is SKIPPED, the good ones still render" {
    # A watcher killed mid-append can leave a half-written line. Aborting on it
    # would hide every finished PR of the session.
    {
        finished_line 1 100 "u1"
        printf '%s\n' '{"number": 2, "url": "u2", "t'
        finished_line 3 300 "u3"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3, #1" "$plain"
    assert_not_contains "#2" "$plain"
}

@test "finished PRs: a torn line with no newline does not eat the next record" {
    # The half-written line and the next append end up concatenated on ONE
    # physical line. That line must be dropped whole, and every OTHER record
    # must still render.
    {
        finished_line 1 100 "u1"
        printf '%s' '{"number": 2, "url": "u2", "t'
        finished_line 3 300 "u3"
        finished_line 4 400 "u4"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #4, #1" "$plain"
    assert_not_contains "#2" "$plain"
}

@test "finished PRs: a duplicate PR number is collapsed, keeping the newest" {
    # Relaunching a watcher on an already-finished PR appends a second line by
    # design — dedup is the renderer's job, not the writer's.
    {
        finished_line 7 100 "old-url"
        finished_line 7 500 "new-url"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #7" "$plain"
    [ "$(printf '%s\n' "$plain" | grep -c '#7')" -eq 1 ]
    assert_contains "new-url" "$raw"
    assert_not_contains "old-url" "$raw"
}

@test "finished PRs: the SAME number in two repos is NOT collapsed" {
    # PR numbers are repo-local, and one session watches branches across several
    # repos. Deduping on the number alone would silently drop one of these.
    {
        finished_line 42 100 "https://github.com/o/repo-a/pull/42" "o/repo-a"
        finished_line 42 200 "https://github.com/o/repo-b/pull/42" "o/repo-b"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #42, #42" "$plain"
    assert_contains "o/repo-a/pull/42" "$raw"
    assert_contains "o/repo-b/pull/42" "$raw"
}

@test "finished PRs: an entry with no repo is skipped" {
    # The repo is what makes the dedup key correct, so a record without one
    # cannot be rendered safely.
    {
        printf '%s\n' '{"number": 1, "url": "u1", "ts": 100}'
        finished_line 3 300 "u3"
    } > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #3" "$plain"
    assert_not_contains "#1" "$plain"
}

@test "finished PRs: at most 10 are rendered, newest first" {
    # The file is append-only and never pruned, so the row width is bounded
    # here. Without the cap a long session wraps the terminal over many lines.
    local i
    for i in $(seq 1 15); do
        finished_line "$i" "$((100 + i))" "u$i"
    done > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #15, #14, #13, #12, #11, #10, #9, #8, #7, #6" "$plain"
    assert_not_contains "#5," "$plain"
    [ "$(printf '%s\n' "$plain" | grep -o '#[0-9]*' | wc -l | tr -d ' ')" -eq 10 ]
}

@test "finished PRs: only the tail of a huge file is parsed" {
    # The parse cost must not grow with the length of the session. Everything
    # older than the last 200 lines is out of scope by design.
    local i
    for i in $(seq 1 260); do
        finished_line "$i" "$((1000 + i))" "u$i"
    done > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #260" "$plain"
    assert_not_contains "#12," "$plain"
}

@test "finished PRs: an entry with an empty url renders as plain text" {
    # The PR fetch can fail on the iteration that records the entry. An OSC 8
    # link to an empty target is worse than no link.
    finished_line 8 100 "" > "$(finished_file)"
    run_status_line
    assert_contains "finished PRs: #8" "$plain"
    assert_not_contains $'\033]8;;\a' "$raw"
}

@test "finished PRs: an entry with a missing field is skipped, not rendered blank" {
    {
        printf '%s\n' '{"number": 1, "repo": "o/r", "url": "u1"}'
        printf '%s\n' '{"url": "u2", "repo": "o/r", "ts": 200}'
        finished_line 3 300 "u3"
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
    finished_line 3009 100 "u9" > "$(finished_file)"

    run_status_line
    local pr_row finished_row
    pr_row="$(printf '%s\n' "$plain" | grep -n 'PR #3011' | cut -d: -f1)"
    finished_row="$(printf '%s\n' "$plain" | grep -n 'finished PRs' | cut -d: -f1)"
    [ -n "$pr_row" ]
    [ -n "$finished_row" ]
    [ "$finished_row" -gt "$pr_row" ]
}

@test "finished PRs: another session's finished file is never read" {
    finished_line 999 100 "u999" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_finished_othersess"
    run_status_line
    assert_not_contains "finished PRs" "$plain"
}

# ---------------------------------------------------------------------------
# Row labels and the terminal-row cap
# ---------------------------------------------------------------------------

@test "closed: reported as a closed PR, never as a dead watcher" {
    # The watcher EXITS when a PR is closed without a merge — a documented
    # terminal condition, not a crash. Reporting it as a death sends the user
    # hunting for a process that left on purpose.
    write_ci_state "feat-a" "feat-a:closed"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    run_status_line
    assert_contains "PR #3011 | pr: closed" "$plain"
    assert_not_contains "died" "$plain"
}

@test "stuck-pending: renders its own label instead of a bare PR row" {
    write_ci_state "feat-a" "feat-a:stuck-pending"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains "PR #3011 | ⚠ checks stuck pending" "$plain"
}

@test "every terminal label renders its own text" {
    local state label
    for state in "no-runs:⚠ no runs" "no-ci:ci: none" \
                 "no-main-ci:ci: no main ci" "timeout:⚠ merge timeout" \
                 "no-ci-configured:ci: no CI configured — safe to merge"; do
        setup
        write_ci_state "feat-a" "feat-a:${state%%:*}"
        label="${state#*:}"
        write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
        spawn_fake_watcher "feat-a"
        run_status_line
        assert_contains "$label" "$plain"
        teardown
    done
}

@test "passed with a BEHIND merge state renders as behind, not passed" {
    write_ci_state "feat-a" "feat-a:passed"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011" "" "BEHIND"
    run_status_line
    assert_contains "PR #3011 | ci: behind" "$plain"
    assert_not_contains "ci: passed" "$plain"
}

@test "passed with a DIRTY merge state renders as conflict" {
    write_ci_state "feat-a" "feat-a:passed"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011" "" "DIRTY"
    run_status_line
    assert_contains "PR #3011 | ci: conflict" "$plain"
}

@test "a state with no PR cache renders the ci state alone" {
    write_ci_state "feat-a" "feat-a:running"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains "ci: running" "$plain"
    assert_not_contains "PR #" "$plain"
}

@test "a PR cache whose state has no label renders the PR alone" {
    write_ci_state "feat-a" "feat-a:some-future-state"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    run_status_line
    assert_contains "PR #3011" "$plain"
    assert_not_contains "|" "$plain"
}

@test "terminal rows are capped at 5, newest first" {
    # Every terminal state file survives for the life of the session, so without
    # a cap a session grows one permanent row per branch it ever watched.
    local i
    for i in 1 2 3 4 5 6 7; do
        write_ci_state "feat-$i" "feat-$i:closed"
        write_pr_cache "feat-$i" "$i" "https://github.com/o/r/pull/$i"
        # Ordering is by state-file mtime, so space the writes apart.
        touch -t "20260101120${i}.00" \
            "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_$(slot_for_branch "feat-$i")"
    done
    run_status_line
    [ "$(printf '%s\n' "$plain" | grep -c 'pr: closed')" -eq 5 ]
    assert_contains "PR #7 | pr: closed" "$plain"
    assert_not_contains "PR #1 " "$plain"
    assert_not_contains "PR #2 " "$plain"
}

@test "live rows are never dropped by the terminal-row cap" {
    local i
    for i in 1 2 3 4 5 6 7; do
        write_ci_state "old-$i" "old-$i:closed"
        write_pr_cache "old-$i" "$i" "https://github.com/o/r/pull/$i"
    done
    write_ci_state "feat-live" "feat-live:running"
    write_pr_cache "feat-live" 900 "https://github.com/o/r/pull/900"
    spawn_fake_watcher "feat-live"
    run_status_line
    assert_contains "PR #900 | ci: running" "$plain"
    [ "$(printf '%s\n' "$plain" | grep -c 'pr: closed')" -eq 5 ]
}

@test "renders correctly under bash 3.2, the macOS system bash" {
    # The shebang is #!/bin/bash, which is 3.2.57 on macOS, and the empty-array
    # guard at the bottom of the script exists for that version specifically.
    # Every other test runs whatever bash is on PATH (5.x here).
    if [ ! -x /bin/bash ]; then
        skip "/bin/bash not present"
    fi
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    finished_line 3009 100 "u9" > "$(finished_file)"

    run_status_line /bin/bash
    assert_contains "PR #3011 | ci: running" "$plain"
    assert_contains "finished PRs: #3009" "$plain"
}

@test "renders the empty case under bash 3.2" {
    if [ ! -x /bin/bash ]; then
        skip "/bin/bash not present"
    fi
    run_status_line /bin/bash
    assert_not_contains "PR #" "$plain"
}

@test "a write_state temp file is never rendered as a second watcher" {
    # write_state renames a temp file into place. If that temp name matched the
    # discovery glob it would be read as a lock-less watcher and reported as a
    # death, right next to the healthy row it came from.
    write_ci_state "feat-a" "feat-a:running"
    write_pr_cache "feat-a" 3011 "https://github.com/o/r/pull/3011"
    spawn_fake_watcher "feat-a"
    printf 'feat-a:running' \
        > "$CLAUDE_NOTIFY_TMP_DIR/.ci_watch_tmp_$(slot_for_branch feat-a).aB3xYz"
    run_status_line
    assert_contains "PR #3011 | ci: running" "$plain"
    assert_not_contains "died" "$plain"
}
