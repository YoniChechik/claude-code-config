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

    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    HOOK_LOG="$CLAUDE_HOOK_LOG_DIR/hooks.log"
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
    # _hook_log.sh, _bashparse.sh and bashparse.jq deliberately NOT copied.
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
    cp "$(SCRIPTS_DIR)"/*.sh "$(SCRIPTS_DIR)"/bashparse.jq "$dir/"
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
    cp "$(SCRIPTS_DIR)"/*.sh "$(SCRIPTS_DIR)"/bashparse.jq "$dir/"
    sed -i '' '1a\
exit 42
' "$dir/pre_tool_use__permission_guard.sh"
    assert_decision ASK "$(dispatch_in "$dir" "$WT" "echo hello")"
}

@test "ask: a sub-check emitting an unrecognizable decision is not forwarded" {
    local dir="$BATS_TEST_TMPDIR/junk"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$(SCRIPTS_DIR)"/bashparse.jq "$dir/"
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
    cp "$(SCRIPTS_DIR)"/*.sh "$(SCRIPTS_DIR)"/bashparse.jq "$dir/"
    assert_decision ALLOW "$(dispatch_in "$dir" "$WT" "echo hello")"
}

@test "dispatcher needs no temp files: a full disk still yields the real decisions" {
    local shim="$BATS_TEST_TMPDIR/diskfull_bin" ro="$BATS_TEST_TMPDIR/ro_tmp"
    mkdir -p "$shim" "$ro"
    printf '#!/bin/sh\necho "mktemp: No space left on device" >&2\nexit 1\n' > "$shim/mktemp"
    chmod +x "$shim/mktemp"
    chmod 500 "$ro"
    local out_deny out_allow out_ask
    out_deny=$(PATH="$shim:$PATH" TMPDIR="$ro" bash_decide "$WT" "$GH $REPO $DEL foo/bar")
    out_allow=$(PATH="$shim:$PATH" TMPDIR="$ro" bash_decide "$WT" "echo hello")
    out_ask=$(PATH="$shim:$PATH" TMPDIR="$ro" bash_decide "$WT" "$GH repo archive foo/bar")
    chmod 700 "$ro"
    assert_decision DENY "$out_deny"
    assert_decision ALLOW "$out_allow"
    assert_decision ASK "$out_ask"
}

@test "a sub-check writing stderr AND a decision on stdout is still caught as a failure" {
    local dir="$BATS_TEST_TMPDIR/both"
    mkdir -p "$dir"
    cp "$(SCRIPTS_DIR)"/*.sh "$(SCRIPTS_DIR)"/bashparse.jq "$dir/"
    sed -i '' '1a\
echo boom >&2
' "$dir/pre_tool_use__base_dir_protect.sh"
    local out
    out=$(jq -nc --arg cwd "$WT" --arg cmd "$GH $REPO $DEL foo/bar" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' \
        | bash "$dir/pre_tool_use__dispatch.sh")
    [[ "$out" == *GUARD_INTERNAL_ERROR* ]]
}

@test "deny: NotebookEdit in the base checkout is blocked via the dispatcher" {
    decide_nb() {
        decide "$(jq -nc --arg cwd "$1" --arg fp "$2" '{tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$fp}}')"
    }
    assert_decision DENY "$(decide_nb "$BASE" "$BASE/nb.ipynb")"
    assert_decision ALLOW "$(decide_nb "$WT" "$WT/nb.ipynb")"
}

STUBS() { echo "$BATS_TEST_TMPDIR/stubs"; }

stub_bin() { # <name> <body>
    mkdir -p "$(STUBS)"
    printf '#!/bin/bash\n%s\n' "$2" >"$(STUBS)/$1"
    chmod +x "$(STUBS)/$1"
}

link_bin() { # <name>
    mkdir -p "$(STUBS)"
    ln -sf "$(command -v "$1")" "$(STUBS)/$1"
}

dispatch_with_path() { # <PATH> <payload-json> [env assignments...] -> ALLOW | ASK | DENY
    local path="$1" payload="$2" out
    shift 2
    out=$(printf '%s' "$payload" | env PATH="$path" "$@" "$BASH" "$HOOK")
    if [ -z "$out" ]; then
        echo "ALLOW"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

bash_payload() { jq -nc --arg cwd "$1" --arg cmd "$2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}'; }

assert_logged() { # <substring>
    grep -qF -- "$1" "$HOOK_LOG" && return 0
    echo "hooks.log does not contain: $1" >&2
    cat "$HOOK_LOG" >&2 2>/dev/null
    return 1
}

@test "fail closed: shfmt missing from PATH asks instead of allowing a would-be deny" {
    link_bin jq
    assert_decision ASK "$(dispatch_with_path "$(STUBS):/usr/bin:/bin" "$(bash_payload "$WT" "$GH $REPO $DEL foo/bar")")"
    assert_logged "shfmt not installed) | $GH $REPO $DEL foo/bar"
}

@test "fail closed: shfmt missing never blocks a non-Bash tool, which needs no parse" {
    link_bin jq
    local payload
    payload=$(jq -nc --arg cwd "$WT" --arg fp "$WT/README.md" '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$fp}}')
    assert_decision ALLOW "$(dispatch_with_path "$(STUBS):/usr/bin:/bin" "$payload")"
}

@test "fail closed: hook input that is not JSON asks" {
    assert_decision ASK "$(decide '{"tool_name":"Bash","tool_input":{"command":')"
    assert_logged "bad hook input JSON"
}

@test "fail closed: hook input whose command is not a string asks" {
    assert_decision ASK "$(decide '{"tool_name":"Bash","cwd":"/","tool_input":{"command":["git","push"]}}')"
}

@test "fail closed: the flattening jq failing asks" {
    link_bin shfmt
    local real_jq
    real_jq=$(command -v jq)
    stub_bin jq "case \"\$*\" in *bashparse.jq*) echo 'jq: error: boom' >&2; exit 5 ;; esac; exec $real_jq \"\$@\""
    assert_decision ASK "$(dispatch_with_path "$(STUBS):$PATH" "$(bash_payload "$WT" "echo hello")")"
    assert_logged "jq failed"
}

@test "fail closed: a hung shfmt times out and asks" {
    link_bin jq
    stub_bin shfmt 'exec sleep 30'
    local start=$SECONDS
    assert_decision ASK "$(dispatch_with_path "$(STUBS):/usr/bin:/bin" "$(bash_payload "$WT" "echo hello")" BASHPARSE_TIMEOUT=1)"
    [ $((SECONDS - start)) -lt 10 ]
    assert_logged "timeout: parse exceeded 1s"
}

@test "fail closed: shfmt exiting nonzero asks" {
    link_bin jq
    stub_bin shfmt 'echo "1:1: something broke" >&2; exit 1'
    assert_decision ASK "$(dispatch_with_path "$(STUBS):/usr/bin:/bin" "$(bash_payload "$WT" "echo hello")")"
    assert_logged "parse error: 1:1: something broke"
}

@test "fail closed: a command bash cannot parse asks" {
    assert_decision ASK "$(bash_decide "$WT" "echo \"unterminated")"
    assert_logged "parse error"
}

@test "the dispatcher parses once and both guards still decide from that one parse" {
    local calls="$BATS_TEST_TMPDIR/shfmt_calls" real_shfmt
    real_shfmt=$(command -v shfmt)
    stub_bin shfmt "echo x >>$calls; exec $real_shfmt \"\$@\""
    assert_decision DENY "$(dispatch_with_path "$(STUBS):$PATH" "$(bash_payload "$BASE" "git $C -am y && $GH repo archive foo/bar")")"
    [ "$(wc -l <"$calls" | tr -d ' ')" = "1" ]
}

@test "an inherited BP_READY=1 cannot make the dispatcher or a guard skip the parse" {
    local out
    out=$(bash_payload "$WT" "$GH $REPO $DEL foo/bar" | BP_READY=1 BP_RC=0 BP_TOOL=Write bash "$HOOK" | jq -r .hookSpecificOutput.permissionDecision)
    assert_decision deny "$out"
    out=$(bash_payload "$WT" "$GH $REPO $DEL foo/bar" | BP_READY=1 BP_RC=0 BP_TOOL=Write bash "$(SCRIPTS_DIR)/pre_tool_use__permission_guard.sh" | jq -r .hookSpecificOutput.permissionDecision)
    assert_decision deny "$out"
}
