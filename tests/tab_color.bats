#!/usr/bin/env bats
#
# Tests for the restored iTerm2 tab-color hooks:
#   - scripts/stop__tab_color.sh          (Stop: green when idle, blue when a
#                                           /loop/cron/wakeup is still armed
#                                           OR a backgrounded task is still
#                                           running/pending)
#   - scripts/notification__tab_color.sh  (Notification: pink unconditionally)
#   - scripts/post_tool_use__reset_color.sh (PostToolUse: clear a painted tab)
#   - scripts/user_prompt_submit__reset_color.sh (UserPromptSubmit: clear a
#     painted tab the instant a new turn starts, before any tool call)
#
# Each script is exercised as a REAL subprocess with a hook JSON payload on
# stdin, exactly like Claude Code runs it. CLAUDE_NOTIFY_TTY redirects the OSC
# writes to a plain file in $BATS_TEST_TMPDIR instead of a real tty.
#
# Assertions go through assert_contains / assert_equals rather than a bare
# `[[ ... ]]`: bash does not fire the ERR trap for the `[[` keyword, so bats
# SWALLOWS a failing non-final `[[ ... ]]` and reports the test as ok.

STOP_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/stop__tab_color.sh"
NOTIF_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/notification__tab_color.sh"
RESET_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/post_tool_use__reset_color.sh"
PROMPT_RESET_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/user_prompt_submit__reset_color.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="testsess"
    TTY="$BATS_TEST_TMPDIR/fake_tty"
    : > "$TTY"
    export CLAUDE_NOTIFY_TTY="$TTY"
}

assert_equals() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %q\nactual:   %q\n' "$1" "$2" >&2
    return 1
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to contain: %q\nactual:              %q\n' "$1" "$2" >&2
    return 1
}

# --- stop__tab_color.sh ------------------------------------------------------

@test "stop: empty session_crons paints the tab green" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess","session_crons":[]}'
    assert_equals 0 "$status"
    assert_contains 'green;brightness;255' "$(cat "$TTY")"
}

@test "stop: no session_crons key at all paints the tab green" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess"}'
    assert_equals 0 "$status"
    assert_contains 'green;brightness;255' "$(cat "$TTY")"
}

@test "stop: an armed /loop wakeup (non-empty session_crons) paints the tab blue" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess","session_crons":[{"id":"1","schedule":"* * * * *","recurring":true,"prompt":"loop"}]}'
    assert_equals 0 "$status"
    assert_contains 'blue;brightness;255' "$(cat "$TTY")"
}

@test "stop: a running backgrounded shell (non-empty background_tasks) paints the tab blue" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess","background_tasks":[{"id":"1","type":"shell","status":"running","description":"sleep 20"}]}'
    assert_equals 0 "$status"
    assert_contains 'blue;brightness;255' "$(cat "$TTY")"
}

@test "stop: a pending background subagent (non-empty background_tasks) paints the tab blue" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess","background_tasks":[{"id":"1","type":"subagent","status":"pending","description":"fork"}]}'
    assert_equals 0 "$status"
    assert_contains 'blue;brightness;255' "$(cat "$TTY")"
}

@test "stop: empty background_tasks alongside empty session_crons paints the tab green" {
    run bash "$STOP_SCRIPT" <<< '{"session_id":"testsess","session_crons":[],"background_tasks":[]}'
    assert_equals 0 "$status"
    assert_contains 'green;brightness;255' "$(cat "$TTY")"
}

@test "stop: malformed stdin drains cleanly, defaults to green, and exits 0" {
    run bash "$STOP_SCRIPT" <<< 'not json'
    assert_equals 0 "$status"
    assert_contains 'green;brightness;255' "$(cat "$TTY")"
}

# --- notification__tab_color.sh ---------------------------------------------

@test "notification: always paints the tab pink" {
    run bash "$NOTIF_SCRIPT" <<< '{"session_id":"testsess"}'
    assert_equals 0 "$status"
    assert_contains 'red;brightness;255' "$(cat "$TTY")"
    assert_contains 'green;brightness;105' "$(cat "$TTY")"
    assert_contains 'blue;brightness;180' "$(cat "$TTY")"
}

# --- post_tool_use__reset_color.sh ------------------------------------------
#
# reset_tab_color() is unconditional (no per-session "was anything painted?"
# guard): the OSC 6 color is a property of the terminal TAB, not of any one
# Claude Code session, so a session that never itself painted anything must
# still clear a stale color left by a PREVIOUS session that used the same
# tab. See _notify.sh's reset_tab_color() comment for the full story.

@test "reset: always clears the tab to default, even with no local paint record" {
    run bash "$RESET_SCRIPT" <<< '{"session_id":"testsess","tool_name":"Bash"}'
    assert_equals 0 "$status"
    assert_contains 'bg;*;default' "$(cat "$TTY")"
}

# --- user_prompt_submit__reset_color.sh -------------------------------------

@test "prompt reset: always clears the tab to default, even with no local paint record" {
    run bash "$PROMPT_RESET_SCRIPT" <<< '{"session_id":"testsess","prompt":"hi"}'
    assert_equals 0 "$status"
    assert_contains 'bg;*;default' "$(cat "$TTY")"
}

# --- settings.json wiring ----------------------------------------------------

@test "settings.json parses and wires Stop/Notification/PostToolUse/UserPromptSubmit to the new scripts" {
    run jq . "$SETTINGS"
    assert_equals 0 "$status"

    run jq -e -r '.hooks.Stop[].hooks[] | select(.command | contains("stop__tab_color.sh")) | .async' "$SETTINGS"
    assert_equals 0 "$status"
    assert_equals "true" "$output"

    run jq -e '.hooks.Notification[].hooks[] | select(.command | contains("notification__tab_color.sh"))' "$SETTINGS"
    assert_equals 0 "$status"

    run jq -e '.hooks.PostToolUse[].hooks[] | select(.command | contains("post_tool_use__reset_color.sh"))' "$SETTINGS"
    assert_equals 0 "$status"

    run jq -e -r '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("user_prompt_submit__reset_color.sh")) | .async' "$SETTINGS"
    assert_equals 0 "$status"
    assert_equals "true" "$output"
}
