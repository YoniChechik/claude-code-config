#!/usr/bin/env bats
#
# Tests for scripts/status_line.sh. Currently scoped to the wakeup-indicator
# segment (fed by scripts/stop__wakeup_status.sh's sidecar, read here via
# _wakeup_next_read in _notify.sh) -- the rest of the script has no dedicated
# coverage yet, so new cases for other segments belong in this same file
# rather than a parallel one.
#
# Exercised as a REAL subprocess with a statusLine JSON payload on stdin,
# exactly like Claude Code runs it. CLAUDE_NOTIFY_TMP_DIR is redirected to
# $BATS_TEST_TMPDIR so the sidecar never touches the real /tmp.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/status_line.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    SESSION="testsess"
    SIDECAR="$CLAUDE_NOTIFY_TMP_DIR/wakeup_next_${SESSION}"
    NOW=$(date +%s)
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO_DIR"
    git -C "$REPO_DIR" init -q >/dev/null 2>&1 || true
}

assert_equals() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %q\nactual:   %q\n' "$1" "$2" >&2
    return 1
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %q\nactual: %q\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in
        (*"$1"*)
            printf 'expected NOT to contain: %q\nactual: %q\n' "$1" "$2" >&2
            return 1
            ;;
    esac
    return 0
}

# Run status_line.sh with session id $1 (default $SESSION) against $REPO_DIR.
run_status_line() {
    local sid="${1:-$SESSION}"
    local payload
    payload=$(jq -n --arg sid "$sid" --arg dir "$REPO_DIR" '{workspace: {current_dir: $dir}, session_id: $sid}')
    run bash "$SCRIPT" <<< "$payload"
}

# ---------------------------------------------------------------------------
# Wakeup indicator segment
# ---------------------------------------------------------------------------

@test "no sidecar file: no wakeup segment rendered, script still exits 0" {
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "a future sidecar renders the wakeup segment with time and label" {
    printf '%s\n%s' "$(( NOW + 600 ))" "check the loop" > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_contains "next:" "$output"
    assert_contains "check the loop" "$output"
}

@test "a sidecar with no label line still renders the time-only segment" {
    printf '%s\n' "$(( NOW + 600 ))" > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_contains "next:" "$output"
}

@test "a past (already-fired) sidecar renders no wakeup segment" {
    printf '%s\n%s' "$(( NOW - 600 ))" "stale" > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
    assert_not_contains "stale" "$output"
}

@test "a corrupt (non-numeric epoch) sidecar renders no segment and does not error" {
    printf '%s\n%s' "not-a-number" "x" > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "an oversized/garbage sidecar degrades gracefully instead of erroring" {
    head -c 100000 /dev/zero | tr '\0' '9' > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "an empty sidecar file renders no segment" {
    : > "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "a missing session_id in the payload: no wakeup segment, no crash" {
    printf '%s\n%s' "$(( NOW + 600 ))" "x" > "$SIDECAR"
    local payload
    payload=$(jq -n --arg dir "$REPO_DIR" '{workspace: {current_dir: $dir}}')
    run bash "$SCRIPT" <<< "$payload"
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "a directory sitting at the sidecar path is treated as missing, not an error" {
    mkdir "$SIDECAR"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
}

@test "the sidecar for a DIFFERENT session id is never shown" {
    printf '%s\n%s' "$(( NOW + 600 ))" "not mine" > "$CLAUDE_NOTIFY_TMP_DIR/wakeup_next_othersession"
    run_status_line
    assert_equals 0 "$status"
    assert_not_contains "next:" "$output"
    assert_not_contains "not mine" "$output"
}
