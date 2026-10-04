#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pre_tool_use__block_plan_mode.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

@test "EnterPlanMode and ExitPlanMode are both denied with a pointer to the /plan skill" {
    for t in EnterPlanMode ExitPlanMode; do
        run bash "$SCRIPT" <<< "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$t\",\"tool_input\":{}}"
        [ "$status" -eq 0 ]
        [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = PreToolUse ]
        [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = deny ]
        [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"/plan skill"* ]]
    done
}

@test "other tools pass through with no output" {
    run bash "$SCRIPT" <<< '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "malformed stdin passes through with no output" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "settings.json wires the block hook on PreToolUse for both plan-mode tools" {
    run jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("/scripts/pre_tool_use__block_plan_mode.sh"))) | .matcher' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "EnterPlanMode|ExitPlanMode" ]
}
