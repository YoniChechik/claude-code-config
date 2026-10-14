#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/pre_tool_use__ask_gate.sh"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export DONE_GATE_MODE=enforce
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

payload() {
    jq -nc --arg h "$1" --arg q "$2" --arg a "${3:-}" \
        '{hook_event_name: "PreToolUse", session_id: "s1", tool_name: "AskUserQuestion",
          tool_input: {questions: [{question: $q, header: $h, options: [{label: "Yes", description: "y"}, {label: "No", description: "n"}], multiSelect: false}]}}
         + (if $a == "" then {} else {agent_id: $a} end)'
}

ask() { payload "$@" | bash "$HOOK"; }

raw() { printf '%s' "$1" | bash "$HOOK"; }

verdict() {
    [ "$status" = 0 ] || { echo "crash:$status"; return; }
    if [ -z "$output" ]; then
        if grep -q "allow ask" "$LOG" 2>/dev/null && ! grep -q "error" "$LOG"; then
            echo allow
        else
            echo "silent"
        fi
        return
    fi
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision'
}

reason() { printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

reset_log() { rm -f "$LOG"; }

@test "a merge permission question is denied with the do-it-and-report reason" {
    run ask "Merge" "Should I merge PR #135?"
    assert_eq deny "$(verdict)"
    assert_contains "If the answer is observable or the action is pre-approved, do it and report." "$(reason)"
    assert_contains "start the question text with \`BLOCKED:<category>\`" "$(reason)"
    case "$(reason)" in (*header*) echo "deny text still suggests a header" >&2; return 1 ;; esac
}

@test "a read-only check offer is denied" {
    run ask "Amplitude" "Do you want me to check the Amplitude console read-only for skipped_chat?"
    assert_eq deny "$(verdict)"
}

@test "BLOCKED:<category> leading the question text is allowed for every human-only category" {
    local c
    for c in credential captcha payment physical destructive-prod-data spending-money irreversible-external-send paradigm-shift; do
        reset_log
        run ask "Need you" "BLOCKED:$c Need you"
        assert_eq allow "$(verdict)" || { echo "category $c" >&2; return 1; }
    done
}

@test "case and separator variants of the tag are accepted" {
    run ask "Payment" "blocked:Payment Enter the card?"
    assert_eq allow "$(verdict)"
    reset_log
    run ask "Payment" "BLOCKED payment Enter the card?"
    assert_eq allow "$(verdict)"
}

@test "a BLOCKED tag only in the header is denied" {
    run ask "BLOCKED:pay" "Enter the card?"
    assert_eq deny "$(verdict)"
}

@test "a BLOCKED tag with a category outside the list is denied" {
    run ask "Q" "BLOCKED:permission Can I merge?"
    assert_eq deny "$(verdict)"
}

@test "the one-by-one and plan headers are allowed" {
    run ask "one-by-one" "1) leave as is 2) group links"
    assert_eq allow "$(verdict)"
    reset_log
    run ask "Plan" "Accept the critique to split task 3?"
    assert_eq allow "$(verdict)"
}

@test "one untagged question among tagged ones denies the call" {
    run raw '{"tool_name":"AskUserQuestion","session_id":"s1","tool_input":{"questions":[{"question":"BLOCKED:payment q","header":"Pay","options":[]},{"question":"merge?","header":"Merge","options":[]}]}}'
    assert_eq deny "$(verdict)"
}

@test "an empty question list is denied" {
    run raw '{"tool_name":"AskUserQuestion","session_id":"s1","tool_input":{"questions":[]}}'
    assert_eq deny "$(verdict)"
}

@test "a subagent is told to report BLOCKED to the orchestrator" {
    run ask "Pay" "BLOCKED:payment card?" sub1
    assert_eq deny "$(verdict)"
    assert_contains "Subagents have no user to ask" "$(reason)"
}

@test "log mode allows and logs the would-be deny" {
    export DONE_GATE_MODE=log
    run ask "Merge" "Should I merge?"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "would_deny ask: deny" "$(cat "$LOG")"
}

@test "an invalid mode value is logged as an error and falls back to the mode file" {
    export DONE_GATE_MODE=enforcee
    mkdir -p "$CLAUDE_STATE_DIR"
    chmod 700 "$CLAUDE_STATE_DIR"
    printf 'enforce\n' >"$CLAUDE_STATE_DIR/done_gate.mode"
    run ask "Merge" "Should I merge?"
    assert_eq deny "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
    assert_contains "error: invalid DONE_GATE_MODE 'enforcee'" "$(cat "$LOG")"
}

@test "the kill switch allows a denied question and logs it" {
    mkdir -p "$CLAUDE_STATE_DIR/override"
    chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/override"
    touch "$CLAUDE_STATE_DIR/override/done_gate.off"
    run ask "Merge" "Should I merge?"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "KILL_SWITCH: ask allowed" "$(cat "$LOG")"
}

@test "other tools pass silently and bad input is logged as an error" {
    run raw '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run raw garbage
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "error: bad hook input JSON" "$(cat "$LOG")"
}
