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

# =============================================================================
# SCOPE ESCAPES: every one of these was AUTO-ALLOWED by the old verb-based
# design. The command reads something inside .claude/, which used to be enough,
# while its real effect lands outside .claude entirely — a redirect, a copy, a
# `-exec`, or a second pipeline stage that is a whole shell.
#
# The rule now: every path-looking argument AND every redirection target, in
# EVERY pipeline segment, must canonicalize under .claude, and the segment's
# verb must be on the allowlist. Anything else falls through to the prompt.
# =============================================================================

@test "fallthrough: pipe into a shell (second segment is not an allowlisted verb)" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt | sh")"
}

@test "fallthrough: read inside .claude, redirect the output outside it" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt > $HOMEDIR/etc/outside")"
}

@test "fallthrough: append-redirect outside .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt >> $HOMEDIR/etc/outside")"
}

@test "fallthrough: cp out of .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cp $HOMEDIR/.claude/existing.txt $HOMEDIR/etc/outside")"
}

@test "fallthrough: mv out of .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "mv $HOMEDIR/.claude/existing.txt $HOMEDIR/etc/outside")"
}

@test "fallthrough: tee writing outside .claude while reading from inside it" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "tee $HOMEDIR/etc/outside < $HOMEDIR/.claude/existing.txt")"
}

@test "fallthrough: find -exec with an outside-.claude path argument" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "find $HOMEDIR/.claude -exec rm $HOMEDIR/etc/outside \;")"
}

@test "fallthrough: echo redirected outside .claude" {
    # `echo` used to be classified "unconditionally safe: never touches files".
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "echo owned > $HOMEDIR/etc/outside")"
}

@test "fallthrough: glued redirect with no space before the target" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "echo owned >$HOMEDIR/etc/outside")"
}

@test "fallthrough: numbered fd redirect outside .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "ls $HOMEDIR/.claude 2>$HOMEDIR/etc/outside")"
}

@test "fallthrough: a relative redirect target that escapes .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR/.claude" "cat existing.txt > ../etc/outside")"
}

@test "fallthrough: a flag whose =value is a path outside .claude" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "grep -r pattern $HOMEDIR/.claude --file=$HOMEDIR/etc/outside")"
}

@test "fallthrough: a command substitution makes the command opaque" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat \$(echo $HOMEDIR/.claude/existing.txt)")"
}

@test "fallthrough: an unexpandable variable makes the command opaque" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "cat \$TARGET")"
}

@test "fallthrough: a subshell wrapping a non-allowlisted verb" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "( sh $HOMEDIR/.claude/existing.txt )")"
}

# =============================================================================
# STILL ALLOWED: the same verbs stay auto-allowed while every path they name
# really does stay inside .claude — including redirections and multi-segment
# pipelines. The redesign must not turn the everyday case into a prompt.
# =============================================================================

@test "allow: redirect from .claude into .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt > $HOMEDIR/.claude/copy.txt")"
}

@test "allow: cp within .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "cp $HOMEDIR/.claude/existing.txt $HOMEDIR/.claude/copy.txt")"
}

@test "allow: pipeline whose every segment is an allowlisted verb scoped to .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "cat $HOMEDIR/.claude/existing.txt | head -5")"
}

@test "allow: tilde-expanded .claude path" {
    # The hook only ever sees the literal text `~/.claude`, so it expands ~
    # itself before canonicalizing.
    HOME="$HOMEDIR"
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "ls ~/.claude")"
}

@test "allow: find with non-path arguments inside .claude" {
    assert_decision ALLOW "$(bash_decide "$HOMEDIR" "find $HOMEDIR/.claude -name '*.md'")"
}

@test "fallthrough: a command with no path at all is not this hook's business" {
    assert_decision FALLTHROUGH "$(bash_decide "$HOMEDIR" "echo hello")"
}
