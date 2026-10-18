#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/config_change__guard.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    NEW="$BATS_TEST_TMPDIR/settings.json"
    LOG="$CLAUDE_HOOK_LOG_DIR/hooks.log"
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

change() {
    jq -nc --arg f "$NEW" --arg s "${1:-user_settings}" '{hook_event_name: "ConfigChange", session_id: "s1", source: $s, file_path: $f}' | bash "$HOOK"
}

without() {
    jq --arg ev "$1" --arg s "$2" '.hooks[$ev] |= map(.hooks |= map(select(.command | endswith("/scripts/" + $s) | not)) | select((.hooks | length) > 0))' "$SETTINGS" >"$NEW"
}

blocked_for() {
    assert_eq 0 "$status"
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
    assert_contains "removes the $1 hook" "$(printf '%s' "$output" | jq -r .reason)"
}

@test "the repo settings.json keeps every gate hook, so a change to it is allowed and logged" {
    cp "$SETTINGS" "$NEW"
    run change
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "allow config change: gate hooks intact" "$(cat "$LOG")"
}

@test "removing any gate hook is blocked and names that hook" {
    local spec ev script label
    for spec in "Stop|stop__coordinator.sh|Stop coordinator" \
        "PostToolUse|post_tool_use__gh_monitor_trigger.sh|merge ledger trigger" \
        "PostToolUse|post_tool_use__probe_ledger.sh|probe ledger" \
        "PostToolUseFailure|post_tool_use__probe_ledger.sh|failed-probe ledger" \
        "PreToolUse|pre_tool_use__ask_gate.sh|question gate" \
        "UserPromptSubmit|prompt_context__done_gate.sh|prompt context" \
        "SessionStart|prompt_context__done_gate.sh|session start context" \
        "ConfigChange|config_change__guard.sh|config change guard"; do
        IFS='|' read -r ev script label <<<"$spec"
        without "$ev" "$script"
        run change
        blocked_for "$label" || { echo "spec $spec" >&2; return 1; }
    done
}

@test "making a gate hook async counts as removing it" {
    local ev
    for ev in Stop:stop__coordinator.sh PostToolUse:post_tool_use__gh_monitor_trigger.sh PreToolUse:pre_tool_use__ask_gate.sh PostToolUse:post_tool_use__probe_ledger.sh PostToolUseFailure:post_tool_use__probe_ledger.sh; do
        jq --arg ev "${ev%%:*}" --arg s "${ev#*:}" '.hooks[$ev] |= map(.hooks |= map(if (.command | endswith("/scripts/" + $s)) then .async = true else . end))' "$SETTINGS" >"$NEW"
        run change
        assert_eq block "$(printf '%s' "$output" | jq -r .decision)" || { echo "event $ev" >&2; return 1; }
    done
}

@test "disableAllHooks is blocked" {
    jq '.disableAllHooks = true' "$SETTINGS" >"$NEW"
    run change
    blocked_for "every hook (disableAllHooks)"
}

@test "project and local settings are never blocked" {
    jq 'del(.hooks.Stop)' "$SETTINGS" >"$NEW"
    run change project_settings
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run change local_settings
    assert_eq "" "$output"
}

@test "an unreadable settings file is skipped and logged" {
    printf '{broken' >"$NEW"
    run change
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "skip: $NEW is not readable JSON" "$(cat "$LOG")"
    rm -f "$NEW"
    run change
    assert_eq "" "$output"
    assert_contains "skip: $NEW is not readable JSON" "$(cat "$LOG")"
}

@test "a missing file_path falls back to settings.json under HOME" {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude"
    jq 'del(.hooks.Stop)' "$SETTINGS" >"$HOME/.claude/settings.json"
    run bash -c "printf '%s' '{\"hook_event_name\":\"ConfigChange\",\"source\":\"user_settings\"}' | bash '$HOOK'"
    assert_eq block "$(printf '%s' "$output" | jq -r .decision)"
}

@test "empty or malformed hook input passes silently" {
    run bash -c "printf '' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run bash -c "printf 'garbage' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "the kill switch allows the change and logs it" {
    mkdir -p "$CLAUDE_STATE_DIR/override"
    chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/override"
    touch "$CLAUDE_STATE_DIR/override/done_gate.off"
    jq 'del(.hooks.Stop)' "$SETTINGS" >"$NEW"
    run change
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "KILL_SWITCH: config change allowed" "$(cat "$LOG")"
}
