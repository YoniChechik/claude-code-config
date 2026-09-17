#!/usr/bin/env bats
#
# Verification matrix for the ask/deny PreToolUse guard
# (scripts/pre_tool_use__permission_guard.sh).
#
# Every case feeds a real hook-input JSON payload to the real hook script and
# asserts the permission decision, so the guard is exercised exactly the way
# the harness exercises it.
#
# The destructive-verb tokens (gh/gcloud/repo/delete/...) are assembled at
# runtime (GH="g""h") so this file's own text cannot trip the guard if the
# suite is ever launched from a shell one-liner that the guard gets to
# inspect — same convention as tests/base_dir_protect.bats.

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__permission_guard.sh"

    GH="g""h"
    REPO="rep""o"
    DEL="del""ete"
    GC="gclo""ud"
    INST="comp""ute"
    INSTANCES="instanc""es"
}

# decide <command> -> NONE | ASK | DENY
decide() {
    local out
    out=$(printf '%s' "$(jq -nc --arg cmd "$1" '{tool_name:"Bash",tool_input:{command:$cmd}}')" | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "NONE"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

assert_decision() { # <expected> <actual>
    if [ "$1" != "$2" ]; then
        echo "expected=$1 got=$2" >&2
        return 1
    fi
}

# =============================================================================
# NORMAL cases: legitimate commands must not be flagged.
# =============================================================================

@test "none: gh pr list is unaffected" {
    assert_decision NONE "$(decide "$GH pr list")"
}

@test "none: gcloud compute instances list is unaffected" {
    assert_decision NONE "$(decide "$GC $INST $INSTANCES list")"
}

@test "none: a commit message merely mentioning the phrase is not a command" {
    assert_decision NONE "$(decide "git commit -m \"note about $GH $REPO $DEL risk\"")"
}

@test "none: bq query (not rm/truncate) is unaffected" {
    assert_decision NONE "$(decide "bq query 'select 1'")"
}

# =============================================================================
# BASELINE deny/ask cases (already worked before this pass; pinned so a
# refactor of the segment pipeline can't quietly regress them).
# =============================================================================

@test "deny: gh repo delete, direct" {
    assert_decision DENY "$(decide "$GH $REPO $DEL foo/bar")"
}

@test "ask: gh repo archive requires confirmation" {
    assert_decision ASK "$(decide "$GH repo archive foo/bar")"
}

@test "ask: gcloud compute instances delete, direct" {
    assert_decision ASK "$(decide "$GC $INST instances $DEL x")"
}

@test "deny: cd foo then gh repo delete (segment split)" {
    assert_decision DENY "$(decide "cd foo && $GH $REPO $DEL foo/bar")"
}

# =============================================================================
# BYPASS REGRESSIONS: every one of these silently fell through to NONE before
# the shared _shell_command_guard.sh normalization/expansion pass. A DENY or
# ASK here is required; NONE is the exact bug this suite exists to catch.
# =============================================================================

@test "deny: command substitution assigned to a variable, \$(...)" {
    assert_decision DENY "$(decide "X=\$($GH $REPO $DEL foo/bar)")"
}

@test "deny: eval with a double-quoted destructive command" {
    assert_decision DENY "$(decide "eval \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: eval with a single-quoted destructive command" {
    assert_decision DENY "$(decide "eval '$GH $REPO $DEL foo/bar'")"
}

@test "deny: bash -c wrapping a destructive command" {
    assert_decision DENY "$(decide "bash -c \"$GH $REPO $DEL foo/bar\"")"
}

@test "ask: backtick command substitution assigned to a variable" {
    assert_decision ASK "$(decide "X=\`$GC $INST instances $DEL x\`")"
}

@test "deny: \`command\` builtin prefix" {
    assert_decision DENY "$(decide "command $GH $REPO $DEL foo/bar")"
}

@test "ask: \`command\` builtin prefix on gcloud" {
    assert_decision ASK "$(decide "command $GC $INST instances $DEL x")"
}

@test "deny: backslash-escaped leading command word" {
    assert_decision DENY "$(decide "\\$GH $REPO $DEL foo/bar")"
}

@test "ask: bare VAR=value env-prefix before gcloud" {
    assert_decision ASK "$(decide "FOO=bar $GC $INST instances $DEL x")"
}

@test "deny: \`env\` builtin prefix" {
    assert_decision DENY "$(decide "env $GH $REPO $DEL foo/bar")"
}

@test "deny: nested command substitution inside a double-quoted string" {
    assert_decision DENY "$(decide "echo \"result: \$($GH $REPO $DEL foo/bar)\"")"
}

@test "ask: pulumi -C flag-prefixed destructive subcommand still recognized" {
    assert_decision ASK "$(decide "pulumi -C infra up")"
}
