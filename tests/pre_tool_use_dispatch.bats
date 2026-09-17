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

# =============================================================================
# FAIL-CLOSED. The dispatcher's contract is "empty output = no opinion = allow",
# which made every internal failure look exactly like a clean pass: with the
# shared library missing, a sub-check that should have DENIED emitted nothing
# and the command was silently allowed. A sub-check is trusted only when it
# exits 0 AND writes nothing to stderr; anything else becomes ASK.
#
# `broken_dir` builds a scripts/ directory that is complete except for the one
# thing under test, so the dispatcher runs exactly as it does in production.
# =============================================================================

SCRIPTS_DIR() { echo "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"; }

dispatch_in() { # <scripts dir> <cwd> <command> -> ALLOW | ASK | DENY
    local out
    out=$(jq -nc --arg cwd "$2" --arg cmd "$3" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' \
        | bash "$1/pre_tool_use__dispatch.sh")
    if [ -z "$out" ]; then
        echo "ALLOW"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

@test "ask: the shared library is missing, so a would-be deny fails closed" {
    local dir="$BATS_TEST_TMPDIR/nolib"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/pre_tool_use__dispatch.sh \
       "$(SCRIPTS_DIR)"/pre_tool_use__base_dir_protect.sh \
       "$(SCRIPTS_DIR)"/pre_tool_use__permission_guard.sh "$dir/"
    # _shell_command_guard.sh deliberately NOT copied.
    assert_decision ASK "$(dispatch_in "$dir" "$WT" "$GH $REPO $DEL foo/bar")"
}

@test "ask: the shared library is missing, so a would-be base-dir deny fails closed" {
    local dir="$BATS_TEST_TMPDIR/nolib2"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/pre_tool_use__dispatch.sh \
       "$(SCRIPTS_DIR)"/pre_tool_use__base_dir_protect.sh \
       "$(SCRIPTS_DIR)"/pre_tool_use__permission_guard.sh "$dir/"
    assert_decision ASK "$(dispatch_in "$dir" "$BASE" "git $C -am y")"
}

@test "ask: a sub-check that writes to stderr is not trusted to have passed" {
    local dir="$BATS_TEST_TMPDIR/noisy"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$dir/"
    # A guard that leaks a diagnostic hit something it did not expect, so its
    # silence on stdout proves nothing. Injected at the top, because the script
    # exits long before its last line on a clean pass.
    sed -i '' '1a\
echo "unexpected diagnostic" >&2
' "$dir/pre_tool_use__base_dir_protect.sh"
    assert_decision ASK "$(dispatch_in "$dir" "$WT" "echo hello")"
}

@test "ask: a sub-check that exits non-zero is not trusted to have passed" {
    local dir="$BATS_TEST_TMPDIR/rc"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$dir/"
    sed -i '' '1a\
exit 42
' "$dir/pre_tool_use__permission_guard.sh"
    assert_decision ASK "$(dispatch_in "$dir" "$WT" "echo hello")"
}

@test "ask: a sub-check emitting an unrecognizable decision is not forwarded" {
    local dir="$BATS_TEST_TMPDIR/junk"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$dir/"
    sed -i '' '1a\
printf "%s" "not json at all"; exit 0
' "$dir/pre_tool_use__permission_guard.sh"
    assert_decision ASK "$(dispatch_in "$dir" "$WT" "echo hello")"
}

@test "allow: a healthy no-rule-matched pass still means allow" {
    # The whole point of failing closed is that it must NOT swallow the normal
    # "nothing matched" path, which is silence plus exit 0.
    local dir="$BATS_TEST_TMPDIR/healthy"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$dir/"
    assert_decision ALLOW "$(dispatch_in "$dir" "$WT" "echo hello")"
}
