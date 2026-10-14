#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/pre_tool_use__ask_gate.sh"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export DONE_GATE_MODE=enforce
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

ask() {
    jq -nc --arg h "$1" --arg q "$2" --arg a "${3:-}" \
        '{hook_event_name: "PreToolUse", session_id: "s1", tool_name: "AskUserQuestion",
          tool_input: {questions: [{question: $q, header: $h, options: [{label: "Yes", description: "y"}, {label: "No", description: "n"}], multiSelect: false}]}}
         + (if $a == "" then {} else {agent_id: $a} end)' | bash "$HOOK"
}

verdict() {
    [ -n "$1" ] || { echo allow; return; }
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision'
}

@test "a merge permission question is denied with the do-it-and-report reason" {
    run ask "Merge" "Should I merge PR #135?"
    assert_eq 0 "$status"
    assert_eq deny "$(verdict "$output")"
    assert_contains "If the answer is observable or the action is pre-approved, do it and report." \
        "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
}

@test "a read-only check offer is denied" {
    run ask "Amplitude" "Do you want me to check the Amplitude console read-only for skipped_chat?"
    assert_eq deny "$(verdict "$output")"
}

@test "BLOCKED:<category> in the header is allowed for every human-only category" {
    local c
    for c in credential captcha payment physical destructive-prod-data spending-money irreversible-external-send paradigm-shift; do
        run ask "BLOCKED:$c" "Need you"
        assert_eq allow "$(verdict "$output")" || { echo "category $c" >&2; return 1; }
    done
}

@test "the BLOCKED tag may lead the question text instead of the short header" {
    run ask "Payment" "BLOCKED:payment Enter the card in the open checkout tab?"
    assert_eq allow "$(verdict "$output")"
}

@test "a BLOCKED tag with a category outside the list is denied" {
    run ask "BLOCKED:permission" "Can I merge?"
    assert_eq deny "$(verdict "$output")"
}

@test "the one-by-one header is allowed" {
    run ask "one-by-one" "1) leave as is 2) group links"
    assert_eq allow "$(verdict "$output")"
}

@test "one untagged question among tagged ones denies the call" {
    run bash -c "jq -nc '{tool_name:\"AskUserQuestion\",session_id:\"s1\",tool_input:{questions:[{question:\"q\",header:\"BLOCKED:payment\",options:[]},{question:\"merge?\",header:\"Merge\",options:[]}]}}' | bash '$HOOK'"
    assert_eq deny "$(verdict "$output")"
}

@test "a subagent is told to report BLOCKED to the orchestrator" {
    run ask "BLOCKED:payment" "card?" sub1
    assert_eq deny "$(verdict "$output")"
    assert_contains "Subagents have no user to ask" "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
}

@test "log mode allows and logs the would-be deny" {
    export DONE_GATE_MODE=log
    run ask "Merge" "Should I merge?"
    assert_eq "" "$output"
    assert_contains "would_deny ask: deny" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "other tools and bad input pass silently" {
    run bash -c "jq -nc '{tool_name:\"Bash\",tool_input:{command:\"ls\"}}' | bash '$HOOK'"
    assert_eq "" "$output"
    run bash -c "printf garbage | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}
