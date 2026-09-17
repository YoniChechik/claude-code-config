#!/usr/bin/env bats
#
# Verification matrix for the PreToolUse dispatcher
# (scripts/pre_tool_use__dispatch.sh), which merges
# pre_tool_use__base_dir_protect.sh and pre_tool_use__permission_guard.sh into
# one hook entry. These tests pin the COMBINATION logic (deny > ask > allow,
# matching how Claude Code itself combines multiple PreToolUse hook results)
# — the individual checks' own behavior is already covered by
# base_dir_protect.bats and permission_guard.bats.
#
# Destructive-verb tokens assembled at runtime, same convention as the other
# suites in this directory.

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__dispatch.sh"

    BASE="$BATS_TEST_TMPDIR/core"
    WT="$BASE/.claude/worktrees/feat"
    mkdir -p "$BASE/.git" "$WT"

    GH="g""h"
    REPO="rep""o"
    DEL="del""ete"
    C="com""mit"
}

# decide <payload-json> -> ALLOW | ASK | DENY
decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "ALLOW"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

bash_decide() { # <cwd> <command>
    decide "$(jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
}

file_decide() { # <tool_name> <cwd> <file_path>
    decide "$(jq -nc --arg t "$1" --arg cwd "$2" --arg fp "$3" \
        '{tool_name:$t,cwd:$cwd,tool_input:{file_path:$fp}}')"
}

assert_decision() { # <expected> <actual>
    if [ "$1" != "$2" ]; then
        echo "expected=$1 got=$2" >&2
        return 1
    fi
}

@test "allow: legit worktree git write, neither check has an opinion" {
    assert_decision ALLOW "$(bash_decide "$WT" "git $C -m x")"
}

@test "deny: base_dir_protect denies, permission_guard has no opinion" {
    assert_decision DENY "$(bash_decide "$BASE" "git $C -am y")"
}

@test "deny: permission_guard denies, base_dir_protect has no opinion" {
    assert_decision DENY "$(bash_decide "$WT" "$GH $REPO $DEL foo/bar")"
}

@test "ask: permission_guard asks, base_dir_protect has no opinion" {
    assert_decision ASK "$(bash_decide "$WT" "$GH repo archive foo/bar")"
}

@test "deny: base_dir_protect denies AND permission_guard denies -> still exactly one deny" {
    assert_decision DENY "$(bash_decide "$BASE" "git $C -am y && $GH $REPO $DEL foo/bar")"
}

@test "deny: base_dir_protect denies while permission_guard only asks -> deny wins" {
    assert_decision DENY "$(bash_decide "$BASE" "git $C -am y && $GH repo archive foo/bar")"
}

@test "deny: file edit outside a worktree still denies via the dispatcher" {
    assert_decision DENY "$(file_decide Write "$BASE" "$BASE/README.md")"
}

@test "allow: file edit inside a worktree still allows via the dispatcher" {
    assert_decision ALLOW "$(file_decide Write "$WT" "$WT/README.md")"
}
