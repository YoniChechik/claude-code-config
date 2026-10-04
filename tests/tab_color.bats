#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/tab_color.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"
BLUE_OSC=$'\033]6;1;bg;red;brightness;0\a\033]6;1;bg;green;brightness;0\a\033]6;1;bg;blue;brightness;255\a'
PINK_OSC=$'\033]6;1;bg;red;brightness;255\a\033]6;1;bg;green;brightness;105\a\033]6;1;bg;blue;brightness;180\a'
DEFAULT_OSC=$'\033]6;1;bg;*;default\a'

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    TTY="$BATS_TEST_TMPDIR/fake_tty"
    : > "$TTY"
    export CLAUDE_NOTIFY_TTY="$TTY"
    PENDING="$BATS_TEST_TMPDIR/tab_pending_s1"
}

assert_equals() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %q\nactual:   %q\n' "$1" "$2" >&2
    return 1
}

fire() {
    : > "$TTY"
    run bash "$SCRIPT" <<< "$1"
    assert_equals 0 "$status"
    assert_equals "" "$output"
}

tab() {
    cat "$TTY"
}

@test "SessionStart paints pink and clears a stale pending marker" {
    printf 'agent-x' > "$PENDING"
    fire '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}'
    assert_equals "$PINK_OSC" "$(tab)"
    [ ! -e "$PENDING" ]
}

@test "SessionEnd resets the tab to the terminal default" {
    printf 'main' > "$PENDING"
    fire '{"hook_event_name":"SessionEnd","session_id":"s1"}'
    assert_equals "$DEFAULT_OSC" "$(tab)"
    [ ! -e "$PENDING" ]
}

@test "UserPromptSubmit paints blue" {
    fire '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "PostToolUse paints blue" {
    fire '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash"}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with nothing in flight paints pink" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[]}'
    assert_equals "$PINK_OSC" "$(tab)"
}

@test "Stop with a running background shell paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"shell","status":"running","description":"sleep 20"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with a pending background subagent paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"subagent","status":"pending","description":"fork"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with a running Monitor paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"monitor","status":"running","description":"tail"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with a running workflow paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"workflow","status":"running","description":"wf"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with an armed /loop wakeup paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[{"id":"1","schedule":"* * * * *","recurring":true,"prompt":"loop"}],"background_tasks":[]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop missing the background fields paints blue rather than guessing idle" {
    fire '{"hook_event_name":"Stop","session_id":"s1"}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "Stop with null background fields paints blue" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":null,"background_tasks":null}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "StopFailure without background fields paints pink" {
    fire '{"hook_event_name":"StopFailure","session_id":"s1","error":"rate_limit"}'
    assert_equals "$PINK_OSC" "$(tab)"
}

@test "StopFailure with a running background task paints blue" {
    fire '{"hook_event_name":"StopFailure","session_id":"s1","background_tasks":[{"id":"1","type":"shell","status":"running","description":"x"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "idle_prompt notification does not paint over a blue background-task tab" {
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"shell","status":"running","description":"sleep 600"}]}'
    assert_equals "$BLUE_OSC" "$(tab)"
    fire '{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
    assert_equals "" "$(tab)"
}

@test "non-human notification types never paint" {
    for t in idle_prompt auth_success agent_completed push_notification computer_use_enter computer_use_exit quota_auto_resume_fired; do
        fire "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\",\"notification_type\":\"$t\"}"
        assert_equals "" "$(tab)"
    done
}

@test "human-needed notification types paint pink" {
    for t in permission_prompt worker_permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input quota_auto_resume_stale; do
        fire "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\",\"notification_type\":\"$t\"}"
        assert_equals "$PINK_OSC" "$(tab)"
    done
}

@test "AskUserQuestion PreToolUse paints pink and its PostToolUse returns to blue" {
    fire '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion"}'
    assert_equals "$PINK_OSC" "$(tab)"
    assert_equals "main" "$(cat "$PENDING")"
    fire '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"AskUserQuestion"}'
    assert_equals "$BLUE_OSC" "$(tab)"
    [ ! -e "$PENDING" ]
}

@test "a background subagent's tool call does not paint over a pending main-thread question" {
    fire '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion"}'
    fire '{"hook_event_name":"PostToolUse","session_id":"s1","agent_id":"sub1","tool_name":"Bash"}'
    assert_equals "" "$(tab)"
    fire '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"sub1"}'
    assert_equals "" "$(tab)"
}

@test "a subagent permission request stays pink across the main turn's Stop until that subagent resumes" {
    fire '{"hook_event_name":"PermissionRequest","session_id":"s1","agent_id":"sub1","tool_name":"Bash"}'
    assert_equals "$PINK_OSC" "$(tab)"
    fire '{"hook_event_name":"Stop","session_id":"s1","session_crons":[],"background_tasks":[{"id":"1","type":"subagent","status":"running","description":"x"}]}'
    assert_equals "" "$(tab)"
    fire '{"hook_event_name":"PostToolUse","session_id":"s1","agent_id":"sub1","tool_name":"Bash"}'
    assert_equals "$BLUE_OSC" "$(tab)"
    [ ! -e "$PENDING" ]
}

@test "a denied tool after a permission request returns to blue via PostToolUseFailure" {
    fire '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}'
    fire '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash"}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "a subagent that stops clears its own pending prompt" {
    fire '{"hook_event_name":"PermissionRequest","session_id":"s1","agent_id":"sub1","tool_name":"Bash"}'
    fire '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"sub1"}'
    assert_equals "$BLUE_OSC" "$(tab)"
    [ ! -e "$PENDING" ]
}

@test "MCP elicitation paints pink and its result returns to blue" {
    fire '{"hook_event_name":"Elicitation","session_id":"s1","mcp_server_name":"x"}'
    assert_equals "$PINK_OSC" "$(tab)"
    fire '{"hook_event_name":"ElicitationResult","session_id":"s1","mcp_server_name":"x"}'
    assert_equals "$BLUE_OSC" "$(tab)"
}

@test "malformed stdin exits 0 silently without painting" {
    fire 'not json'
    assert_equals "" "$(tab)"
}

@test "settings.json routes every tab-color event to tab_color.sh synchronously" {
    run jq -e . "$SETTINGS"
    assert_equals 0 "$status"
    for event in SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest Elicitation ElicitationResult Notification PostToolUse PostToolUseFailure SubagentStop Stop StopFailure; do
        run jq -r --arg e "$event" '[.hooks[$e][] | select(any(.hooks[]; .command | endswith("/scripts/tab_color.sh"))) | .hooks[] | (.async // false)] | map(tostring) | join(",")' "$SETTINGS"
        assert_equals 0 "$status"
        assert_equals "false" "$output"
    done
}

@test "settings.json scopes the PreToolUse and SessionStart tab-color hooks" {
    run jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("/scripts/tab_color.sh"))) | .matcher' "$SETTINGS"
    assert_equals "AskUserQuestion" "$output"
    run jq -r '.hooks.SessionStart[] | select(any(.hooks[]; .command | endswith("/scripts/tab_color.sh"))) | .matcher' "$SETTINGS"
    assert_equals "startup|resume|clear" "$output"
    run jq -r '[.hooks.StopFailure[] | select(any(.hooks[]; .command | endswith("/scripts/tab_color.sh"))) | .matcher // "none"] | join(",")' "$SETTINGS"
    assert_equals "none" "$output"
}

@test "no old per-event tab-color scripts remain" {
    for f in stop__tab_color.sh notification__tab_color.sh post_tool_use__reset_color.sh user_prompt_submit__reset_color.sh; do
        [ ! -e "${BATS_TEST_DIRNAME}/../scripts/$f" ]
        run grep -c "$f" "$SETTINGS"
        assert_equals 0 "$output"
    done
}
