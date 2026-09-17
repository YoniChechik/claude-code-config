#!/usr/bin/env bats
#
# Tests for scripts/stop__session_name_reminder.sh — the Stop hook that nudges
# Claude to re-run /session-name at most once per 30 minutes.
#
# The script is exercised as a REAL subprocess with a hook JSON payload on
# stdin, exactly like Claude Code runs it. CLAUDE_NOTIFY_TMP_DIR is redirected
# to $BATS_TEST_TMPDIR so the state file never touches the real /tmp.
#
# Assertions go through assert_contains / assert_equals rather than a bare
# `[[ ... ]]`: bash does not fire the ERR trap for the `[[` keyword, so bats
# SWALLOWS a failing non-final `[[ ... ]]` and reports the test as ok.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/stop__session_name_reminder.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    SESSION="testsess"
    STATE_FILE="$CLAUDE_NOTIFY_TMP_DIR/session_name_reminder_${SESSION}"
    NOW=$(date +%s)
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

# Write a raw last-fired value into the state file of session id $1.
write_state() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/session_name_reminder_${1}"
}

# Run the hook as a real subprocess with a session id on the stdin payload.
run_hook() {
    run bash -c "printf '%s' '{\"session_id\":\"$1\"}' | bash '$SCRIPT'"
}

# Run the hook with a raw stdin payload (for the malformed/empty cases).
run_hook_raw() {
    run bash -c "printf '%s' '$1' | bash '$SCRIPT'"
}

# ---------------------------------------------------------------------------
# Mandatory acceptance tests
# ---------------------------------------------------------------------------

@test "no reminder before 30 minutes have elapsed" {
    write_state "$SESSION" "$(( NOW - 1000 ))"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
}

@test "reminder fires after more than 30 minutes have elapsed" {
    write_state "$SESSION" "$(( NOW - 3600 ))"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    # Parse the JSON, so the test pins the output SHAPE and not just a substring.
    local event context
    event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
    context=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_equals "Stop" "$event"
    assert_contains "/session-name" "$context"
}

@test "the timestamp resets after firing, so there is no immediate re-fire" {
    write_state "$SESSION" "$(( NOW - 3600 ))"
    run_hook "$SESSION"
    assert_contains "additionalContext" "$output"
    # Second run, no further state manipulation: the gate must be re-engaged.
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "cold start initializes the state file without firing" {
    [ ! -e "$STATE_FILE" ]
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ -f "$STATE_FILE" ]
    local stored
    stored=$(cat "$STATE_FILE")
    [[ "$stored" =~ ^[0-9]+$ ]] || { printf 'not numeric: %q\n' "$stored" >&2; return 1; }
    [ "$(( stored - NOW ))" -ge -5 ]
    [ "$(( stored - NOW ))" -le 5 ]
}

@test "a corrupt state file is treated as a fresh cold start" {
    write_state "$SESSION" "not-a-timestamp"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    local stored
    stored=$(cat "$STATE_FILE")
    [[ "$stored" =~ ^[0-9]+$ ]] || { printf 'not numeric: %q\n' "$stored" >&2; return 1; }
}

@test "a payload with no session_id exits 0 and writes nothing" {
    run_hook_raw '{}'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
}

@test "the 1800-second threshold is strict: 1800 is silent, 1801 fires" {
    write_state boundary_a "$(( NOW - 1800 ))"
    run_hook boundary_a
    assert_equals 0 "$status"
    assert_equals "" "$output"

    write_state boundary_b "$(( NOW - 1801 ))"
    run_hook boundary_b
    assert_equals 0 "$status"
    assert_contains "/session-name" \
        "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
}

# ---------------------------------------------------------------------------
# settings.json wiring (cheap, so colocated here)
# ---------------------------------------------------------------------------

@test "settings.json parses and wires the Stop hook to this script" {
    run jq . "$SETTINGS"
    assert_equals 0 "$status"
    run jq -e -r '.hooks.Stop[].hooks[].command' "$SETTINGS"
    assert_equals 0 "$status"
    assert_contains "stop__session_name_reminder.sh" "$output"
}
