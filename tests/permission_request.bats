#!/usr/bin/env bats
#
# Verification matrix for the PermissionRequest auto-allow guard
# (scripts/permission_request.sh).
#
# The guard auto-allows edits/reads/rm's confined to a `.claude/` directory.
# Before the path-traversal fix, "confined to" was checked with a raw
# substring/glob match on the UNRESOLVED path string, so
# `<claude-dir>/../../etc/hosts` auto-allowed (it contains "/.claude/") while
# actually pointing well outside it. These tests pin that the check now
# canonicalizes the path first.

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/permission_request.sh"

    HOMEDIR="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOMEDIR/.claude" "$HOMEDIR/etc"
    touch "$HOMEDIR/.claude/existing.txt" "$HOMEDIR/etc/hosts"
}

# decide <json> -> ALLOW | FALLTHROUGH
decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "FALLTHROUGH"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior' | tr 'a-z' 'A-Z'
    fi
}

file_decide() { # <tool_name> <cwd> <file_path> -> ALLOW | FALLTHROUGH
    decide "$(jq -nc --arg t "$1" --arg cwd "$2" --arg fp "$3" \
        '{tool_name:$t,cwd:$cwd,tool_input:{file_path:$fp}}')"
}

bash_decide() { # <cwd> <command> -> ALLOW | FALLTHROUGH
    decide "$(jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
}

assert_decision() { # <expected> <actual>
    if [ "$1" != "$2" ]; then
        echo "expected=$1 got=$2" >&2
        return 1
    fi
}

# =============================================================================
# ALLOWED: genuine .claude/ paths, including a Write to a file that doesn't
# exist yet (the common case — canonicalization must not require existence).
# =============================================================================

@test "allow: Write to an existing file under .claude" {
    assert_decision ALLOW "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claude/existing.txt")"
}

@test "allow: Write to a brand-new file under .claude" {
    assert_decision ALLOW "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claude/brand_new_file.md")"
}

@test "allow: Write to a brand-new file under a brand-new subdirectory of .claude" {
    assert_decision ALLOW "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claude/new/sub/dir/file.md")"
}

@test "allow: rm of a file under .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "rm $HOMEDIR/.claude/existing.txt")"
}

@test "allow: cat of a file under .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt")"
}

# =============================================================================
# DENIED (fall through to normal prompt): path-traversal lookalikes. Every one
# of these contains the substring "/.claude/" but resolves OUTSIDE it — the
# exact bypass shape flagged in the security review.
# =============================================================================

@test "fallthrough: Write traversal out of .claude to /etc/hosts" {
    assert_decision FALLTHROUGH "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claude/../etc/hosts")"
}

@test "fallthrough: Write traversal out of .claude to a brand-new file outside it" {
    assert_decision FALLTHROUGH "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claude/../etc/newfile_outside.txt")"
}

@test "fallthrough: rm traversal out of .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "rm $HOMEDIR/.claude/../etc/hosts")"
}

@test "fallthrough: cat traversal out of .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/../etc/hosts")"
}

@test "fallthrough: rm mixing one real .claude token with one traversal token" {
    # SALL must go false the moment ANY token resolves outside .claude, even
    # if another token in the same segment is legitimate.
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "rm $HOMEDIR/.claude/existing.txt $HOMEDIR/.claude/../etc/hosts")"
}

@test "fallthrough: Write to a path that is merely named .claudeXYZ (lookalike prefix)" {
    mkdir -p "$HOMEDIR/.claudeXYZ"
    assert_decision FALLTHROUGH "$(file_decide Write "$HOMEDIR" "$HOMEDIR/.claudeXYZ/file.txt")"
}

@test "fallthrough: a completely unrelated file is never auto-allowed" {
    assert_decision FALLTHROUGH "$(file_decide Write "$HOMEDIR" "$HOMEDIR/etc/hosts")"
}
