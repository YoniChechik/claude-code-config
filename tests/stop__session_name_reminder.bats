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
# The payload is built with `jq -n --arg` and fed in as a herestring, so the
# session id NEVER passes through shell-string interpolation. That is what lets
# an adversarial id (quotes, `../`, `$( )`) reach the script as literal JSON
# data the way Claude Code delivers it, instead of corrupting the test's own
# command line.
run_hook() {
    local payload
    payload=$(jq -n --arg sid "$1" '{session_id: $sid}')
    run bash "$SCRIPT" <<< "$payload"
}

# Run the hook with a raw stdin payload (for the malformed/empty cases).
run_hook_raw() {
    run bash "$SCRIPT" <<< "$1"
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

@test "the emitted JSON has exactly hookSpecificOutput.{hookEventName,additionalContext} and nothing else" {
    write_state "$SESSION" "$(( NOW - 3600 ))"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    local top_keys inner_keys
    top_keys=$(printf '%s' "$output" | jq -S -c 'keys')
    inner_keys=$(printf '%s' "$output" | jq -S -c '.hookSpecificOutput | keys')
    # Pins that no decision/reason/systemMessage ever sneaks in alongside
    # additionalContext -- this hook is model-facing only, never user-facing.
    assert_equals '["hookSpecificOutput"]' "$top_keys"
    assert_equals '["additionalContext","hookEventName"]' "$inner_keys"
}

@test "malformed non-JSON stdin drains cleanly and exits 0 without writing state" {
    run_hook_raw 'not json at all { [ garbled'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
}

@test "completely empty stdin exits 0 and writes nothing" {
    run bash "$SCRIPT" < /dev/null
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
}

# ---------------------------------------------------------------------------
# Corrupt / hostile state values
# ---------------------------------------------------------------------------

@test "a leading-zero state value is corrupt, not octal: exit 0, no shell error" {
    # Regression pin: bash arithmetic reads a leading-zero operand as OCTAL, so
    # "09" once aborted the script with "value too great for base" and exit 1.
    # $output holds stdout AND stderr, so an empty $output also proves no shell
    # error leaked out.
    write_state "$SESSION" "09"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    # Treated as a cold start, so the clock is re-initialized to a sane value.
    local stored
    stored=$(cat "$STATE_FILE")
    [[ "$stored" =~ ^[1-9][0-9]*$ ]] || { printf 'not numeric: %q\n' "$stored" >&2; return 1; }
    [ "$(( stored - NOW ))" -ge -5 ]
    [ "$(( stored - NOW ))" -le 5 ]
}

@test "a future timestamp is rewritten instead of wedging the reminder off" {
    # Clock skew (or a corrupt-but-numeric far-future value) must not park the
    # reminder until the real clock catches up.
    write_state "$SESSION" "$(( NOW + 5000 ))"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    local stored
    stored=$(cat "$STATE_FILE")
    [ "$(( stored - NOW ))" -ge -5 ]
    [ "$(( stored - NOW ))" -le 5 ]
}

# ---------------------------------------------------------------------------
# Hostile session ids and unusable state paths
# ---------------------------------------------------------------------------

@test "a session id with path separators is rejected and writes nothing anywhere" {
    local outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside/sub"
    export CLAUDE_NOTIFY_TMP_DIR="$outside/sub"
    run_hook "../../pwned"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$outside/sub")"
    assert_equals "sub" "$(ls "$outside")"
}

@test "a session id with shell metacharacters reaches the script as data and is rejected" {
    run_hook '$(touch '"$BATS_TEST_TMPDIR"'/pwned); echo "x"'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
}

@test "a directory sitting at the state-file path is left alone, not leaked into" {
    mkdir "$STATE_FILE"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    # The old code mv'd a fresh temp file INSIDE the directory on every Stop.
    assert_equals "" "$(ls "$STATE_FILE")"
}

@test "an unwritable state dir degrades to a silent exit 0" {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR/missing-dir"
    run_hook "$SESSION"
    assert_equals 0 "$status"
    assert_equals "" "$output"
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
