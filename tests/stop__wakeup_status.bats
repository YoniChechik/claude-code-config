#!/usr/bin/env bats
#
# Tests for scripts/stop__wakeup_status.sh -- the Stop hook that mirrors the
# Stop hook input's session_crons array (ScheduleWakeup/CronCreate/`/loop`)
# into a per-session sidecar file for status_line.sh to render.
#
# The script is exercised as a REAL subprocess with a hook JSON payload on
# stdin, exactly like Claude Code runs it. CLAUDE_NOTIFY_TMP_DIR is redirected
# to $BATS_TEST_TMPDIR so the sidecar never touches the real /tmp.
# WAKEUP_STATUS_NOW_EPOCH pins "now" for the python cron matcher so the cron
# assertions are deterministic instead of racing the real wall clock.
#
# Assertions go through assert_contains / assert_equals rather than a bare
# `[[ ... ]]`: bash does not fire the ERR trap for the `[[` keyword, so bats
# SWALLOWS a failing non-final `[[ ... ]]` and reports the test as ok.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/stop__wakeup_status.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    SESSION="testsess"
    SIDECAR="$CLAUDE_NOTIFY_TMP_DIR/wakeup_next_${SESSION}"
    NOW=$(date +%s)
    export WAKEUP_STATUS_NOW_EPOCH="$NOW"
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

# Run the hook with session_id $1 and a session_crons JSON array $2 (a raw
# jq array literal). Built with `jq -n --argjson`, so nothing here passes
# through shell-string interpolation into the payload.
run_hook_with_crons() {
    local payload
    payload=$(jq -n --arg sid "$1" --argjson crons "$2" '{session_id: $sid, session_crons: $crons}')
    run bash "$SCRIPT" <<< "$payload"
}

# Run the hook with a raw stdin payload (for the malformed/empty/no-crons
# cases).
run_hook_raw() {
    run bash "$SCRIPT" <<< "$1"
}

# A 5-field cron string that fires at the exact minute of epoch $1 with
# wildcard day-of-month/month/day-of-week (used for one-shot entries, and as
# a building block for recurring ones). Leading zeros in the printed fields
# are fine -- python's int() reads them as base 10, not octal like bash
# arithmetic would.
schedule_at() {
    date -r "$1" "+%M %H %d %m *"
}

# ---------------------------------------------------------------------------
# Cold start / no-op paths
# ---------------------------------------------------------------------------

@test "no session_crons key at all: exits 0, no output, no sidecar" {
    run_hook_raw "$(jq -n --arg sid "$SESSION" '{session_id: $sid}')"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$SIDECAR" ]
}

@test "an explicit empty session_crons array: exits 0, no sidecar" {
    run_hook_with_crons "$SESSION" '[]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$SIDECAR" ]
}

@test "empty session_crons clears a PREVIOUSLY armed sidecar -- the until-it-finishes behavior" {
    local target=$(( NOW + 300 ))
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$(schedule_at "$target")" '[{id:"c1", schedule:$s, recurring:false, prompt:"x"}]')"
    [ -f "$SIDECAR" ]
    run_hook_with_crons "$SESSION" '[]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$SIDECAR" ]
}

# ---------------------------------------------------------------------------
# Malformed / missing input
# ---------------------------------------------------------------------------

@test "a payload with no session_id exits 0 and writes nothing" {
    run_hook_raw '{"session_crons":[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"x"}]}'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
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
# Real (non-empty) session_crons
# ---------------------------------------------------------------------------

@test "a single one-shot entry writes the correct epoch and label to the sidecar" {
    local target=$(( NOW + 300 ))
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$(schedule_at "$target")" '[{id:"c1", schedule:$s, recurring:false, prompt:"check the loop"}]')"
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ -f "$SIDECAR" ]
    local stored_epoch stored_label diff
    stored_epoch=$(sed -n '1p' "$SIDECAR")
    stored_label=$(sed -n '2p' "$SIDECAR")
    diff=$(( stored_epoch - target ))
    # Cron is minute-granularity, so allow a small tolerance either side.
    [ "$diff" -ge -60 ] && [ "$diff" -le 60 ]
    assert_equals "check the loop" "$stored_label"
}

@test "multiple entries: the EARLIEST upcoming fire time wins, not list order" {
    local near=$(( NOW + 300 )) far=$(( NOW + 3600 ))
    run_hook_with_crons "$SESSION" "$(jq -n --arg f "$(schedule_at "$far")" --arg n "$(schedule_at "$near")" '[
        {id:"far", schedule:$f, recurring:false, prompt:"later"},
        {id:"near", schedule:$n, recurring:false, prompt:"sooner"}
    ]')"
    assert_equals 0 "$status"
    [ -f "$SIDECAR" ]
    assert_equals "sooner" "$(sed -n '2p' "$SIDECAR")"
}

@test "a recurring entry resolves to the next matching fire time via search" {
    local target=$(( NOW + 120 ))
    local schedule
    schedule=$(date -r "$target" "+%M %H * * *")
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$schedule" '[{id:"c1", schedule:$s, recurring:true, prompt:"daily"}]')"
    assert_equals 0 "$status"
    [ -f "$SIDECAR" ]
    local stored_epoch diff
    stored_epoch=$(sed -n '1p' "$SIDECAR")
    diff=$(( stored_epoch - target ))
    [ "$diff" -ge -60 ] && [ "$diff" -le 60 ]
}

@test "vixie-cron OR semantics: a match on EITHER day-of-month or day-of-week fires, when both are restricted" {
    local target=$(( NOW + 120 ))
    local min hour cron_dow today_dom bogus_dom
    min=$(date -r "$target" "+%M")
    hour=$(date -r "$target" "+%H")
    cron_dow=$(date -r "$target" "+%w")
    today_dom=$(date -r "$NOW" "+%d")
    bogus_dom=31
    [ "$((10#$today_dom))" -eq 31 ] && bogus_dom=1
    local schedule="$min $hour $bogus_dom * $cron_dow"
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$schedule" '[{id:"c1", schedule:$s, recurring:true, prompt:"or-test"}]')"
    assert_equals 0 "$status"
    [ -f "$SIDECAR" ]
    local stored_epoch diff
    stored_epoch=$(sed -n '1p' "$SIDECAR")
    diff=$(( stored_epoch - target ))
    [ "$diff" -ge -60 ] && [ "$diff" -le 60 ]
}

# ---------------------------------------------------------------------------
# Corrupt / unparseable entries -- degrade, never crash
# ---------------------------------------------------------------------------

@test "an entry with a malformed (wrong field count) schedule is skipped, sidecar stays absent" {
    run_hook_with_crons "$SESSION" '[{"id":"c1","schedule":"garbage","recurring":false,"prompt":"x"}]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$SIDECAR" ]
}

@test "an entry with an out-of-range field value is skipped, sidecar stays absent" {
    run_hook_with_crons "$SESSION" '[{"id":"c1","schedule":"99 99 99 99 *","recurring":false,"prompt":"x"}]'
    assert_equals 0 "$status"
    [ ! -e "$SIDECAR" ]
}

@test "one malformed entry does not block a valid sibling entry from being used" {
    local target=$(( NOW + 300 ))
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$(schedule_at "$target")" '[
        {id:"bad", schedule:"nonsense", recurring:false, prompt:"bad"},
        {id:"good", schedule:$s, recurring:false, prompt:"good"}
    ]')"
    assert_equals 0 "$status"
    [ -f "$SIDECAR" ]
    assert_equals "good" "$(sed -n '2p' "$SIDECAR")"
}

@test "a recurring entry with no match inside the 8-day search horizon leaves the sidecar absent" {
    # day-of-month 30, month restricted to a month NOT containing day 30 is
    # impossible without real calendar logic, so instead pin an impossible
    # combination: Feb 30th, which no real month ever satisfies.
    run_hook_with_crons "$SESSION" '[{"id":"c1","schedule":"0 9 30 2 *","recurring":true,"prompt":"never"}]'
    assert_equals 0 "$status"
    [ ! -e "$SIDECAR" ]
}

# ---------------------------------------------------------------------------
# Label sanitization (reuses _sanitize_and_cap's contract)
# ---------------------------------------------------------------------------

@test "the stored label is sanitized (no backslash) and capped at 35 codepoints" {
    local target=$(( NOW + 300 ))
    local long_prompt='This prompt is definitely longer than thirty five codepoints and has a \ backslash in it'
    run_hook_with_crons "$SESSION" "$(jq -n --arg s "$(schedule_at "$target")" --arg p "$long_prompt" '[{id:"c1", schedule:$s, recurring:false, prompt:$p}]')"
    assert_equals 0 "$status"
    [ -f "$SIDECAR" ]
    local stored_label
    stored_label=$(sed -n '2p' "$SIDECAR")
    case "$stored_label" in (*'\'*) return 1 ;; esac
    [ "${#stored_label}" -le 35 ]
}

# ---------------------------------------------------------------------------
# Hostile session ids and unusable sidecar paths
# ---------------------------------------------------------------------------

@test "a session id with path separators is rejected and writes nothing anywhere" {
    local outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside/sub"
    export CLAUDE_NOTIFY_TMP_DIR="$outside/sub"
    run_hook_with_crons "../../pwned" '[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"x"}]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$outside/sub")"
    assert_equals "sub" "$(ls "$outside")"
}

@test "a session id with shell metacharacters reaches the script as data and is rejected" {
    run_hook_with_crons '$(touch '"$BATS_TEST_TMPDIR"'/pwned); echo "x"' '[]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    assert_equals "" "$(ls "$CLAUDE_NOTIFY_TMP_DIR")"
}

@test "a directory sitting at the sidecar path is left alone, not leaked into" {
    mkdir "$SIDECAR"
    run_hook_with_crons "$SESSION" '[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"x"}]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
    assert_equals "" "$(ls "$SIDECAR")"
}

@test "an unwritable sidecar dir degrades to a silent exit 0" {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR/missing-dir"
    run_hook_with_crons "$SESSION" '[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"x"}]'
    assert_equals 0 "$status"
    assert_equals "" "$output"
}

# ---------------------------------------------------------------------------
# settings.json wiring (cheap, so colocated here)
# ---------------------------------------------------------------------------

@test "settings.json parses and wires the Stop hook to this script, async" {
    run jq . "$SETTINGS"
    assert_equals 0 "$status"
    run jq -e -r '.hooks.Stop[].hooks[] | select(.command | contains("stop__wakeup_status.sh")) | .async' "$SETTINGS"
    assert_equals 0 "$status"
    assert_equals "true" "$output"
}
