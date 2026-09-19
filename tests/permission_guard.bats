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

# =============================================================================
# SHELL-CODE ARGUMENT BYPASSES. `_unwrap_code_arg` used to require the code
# string to be the LAST thing in the segment, spelled with a bare `-c`, after a
# bare interpreter name. Each of these defeats one of those assumptions.
# =============================================================================

@test "deny: bash -c with trailing argv after the code string" {
    # The trailing word becomes $0 for the spawned shell; the code still runs.
    assert_decision DENY "$(decide "bash -c \"$GH $REPO $DEL foo/bar\" sentinel")"
}

@test "deny: bash -lc with combined short flags" {
    assert_decision DENY "$(decide "bash -lc \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: sh -ic with combined short flags" {
    assert_decision DENY "$(decide "sh -ic '$GH $REPO $DEL foo/bar'")"
}

@test "deny: an absolute path to the interpreter" {
    assert_decision DENY "$(decide "/bin/bash -c \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: quote concatenation inside the command word" {
    assert_decision DENY "$(decide "g\"h\" $REPO $DEL foo/bar")"
}

@test "deny: quote concatenation inside a subcommand word" {
    assert_decision DENY "$(decide "$GH re\"\"po $DEL foo/bar")"
}

@test "deny: single-quote concatenation inside the command word" {
    assert_decision DENY "$(decide "g'h' $REPO $DEL foo/bar")"
}

@test "deny: an absolute path to the gh binary" {
    assert_decision DENY "$(decide "/usr/bin/$GH $REPO $DEL foo/bar")"
}

@test "deny: a relative path to the gh binary" {
    assert_decision DENY "$(decide "./bin/$GH $REPO $DEL foo/bar")"
}

@test "deny: env with an argument-taking flag before the real command" {
    # The env stripper skipped `-u` but not its argument, so `FOO` was read as
    # the command and the real invocation was never inspected.
    assert_decision DENY "$(decide "env -u FOO $GH $REPO $DEL foo/bar")"
}

@test "deny: env -i with an assignment before the real command" {
    assert_decision DENY "$(decide "env -i PATH=/usr/bin $GH $REPO $DEL foo/bar")"
}

@test "deny: builtin wrapper prefix" {
    assert_decision DENY "$(decide "builtin command $GH $REPO $DEL foo/bar")"
}

@test "deny: exec wrapper prefix" {
    assert_decision DENY "$(decide "exec $GH $REPO $DEL foo/bar")"
}

# =============================================================================
# SHELL GRAMMAR. The segment splitter cut on `;`/`&`/`|` only, so a command body
# that arrived with a grammar keyword still attached (`{ ...`, `then ...`,
# `do ...`) never matched a prefix-anchored rule.
# =============================================================================

@test "deny: brace group" {
    assert_decision DENY "$(decide "{ $GH $REPO $DEL foo/bar; }")"
}

@test "deny: if/then construct" {
    assert_decision DENY "$(decide "if true; then $GH $REPO $DEL foo/bar; fi")"
}

@test "deny: if/else construct, destructive command in the else body" {
    assert_decision DENY "$(decide "if false; then echo no; else $GH $REPO $DEL foo/bar; fi")"
}

@test "deny: while/do construct" {
    assert_decision DENY "$(decide "while true; do $GH $REPO $DEL foo/bar; done")"
}

@test "deny: for/do construct" {
    assert_decision DENY "$(decide "for i in 1 2; do $GH $REPO $DEL foo/bar; done")"
}

@test "deny: subshell grouping" {
    assert_decision DENY "$(decide "( $GH $REPO $DEL foo/bar )")"
}

@test "ask: a grammar-wrapped ask-level command is still recognized" {
    assert_decision ASK "$(decide "{ $GC $INST $INSTANCES $DEL x; }")"
}

# =============================================================================
# MOST-RESTRICTIVE WINS. Rules are checked in a fixed order and used to exit on
# the first match, so a compound command that tripped an EARLY ask rule never
# reached the LATER deny rule its other half would have matched. Each pair below
# puts the ask rule first in file order and the deny rule second.
# =============================================================================

@test "deny: gh ask-rule first, raw-HTTP deny-rule second" {
    local url="https://api.git""hub.com/repos/sun""say-ltd/x"
    assert_decision DENY "$(decide "$GH repo archive foo/bar && curl -X DELETE $url")"
}

@test "deny: gcloud ask-rule first, gcloud-run prod deny-rule second" {
    local cmd="$GC $INST $INSTANCES $DEL x && $GC run deploy --project=production-490411"
    assert_decision DENY "$(decide "$cmd")"
}

@test "deny: bq ask-rule first, pulumi prod deny-rule second" {
    assert_decision DENY "$(decide "bq rm mydataset.mytable && pulumi up --stack production")"
}

@test "deny: gh ask-rule first, gh repo delete deny-rule later in the same command" {
    assert_decision DENY "$(decide "$GH repo archive foo/bar && $GH $REPO $DEL foo/bar")"
}

@test "deny: supabase ask-rule first, bare-target deny-rule second" {
    assert_decision DENY "$(decide "supabase migration push && supabase db reset")"
}

@test "ask: an ask-only compound command still asks (deny is never invented)" {
    assert_decision ASK "$(decide "$GH repo archive foo/bar && $GH repo rename baz")"
}

@test "ask: a broken shared library fails closed instead of silently allowing" {
    # With _shell_command_guard.sh unavailable every rule matches nothing, which
    # is indistinguishable from a clean pass unless the guard says so.
    local dir="$BATS_TEST_TMPDIR/brokenlib"
    mkdir -p "$dir"
    cp "$HOOK" "$dir/"
    local out
    out=$(jq -nc --arg cmd "$GH $REPO $DEL foo/bar" '{tool_name:"Bash",tool_input:{command:$cmd}}' \
        | bash "$dir/$(basename "$HOOK")")
    [ -n "$out" ]
    assert_decision ASK "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
}
