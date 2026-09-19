#!/usr/bin/env bats
#
# Tests for scripts/post_tool_use__ci_watch_trigger.sh — the PostToolUse:Bash
# hook that auto-launches the one-shot CI watcher.
#
# Strategy:
#   - The REAL hook is run end to end, fed a real PostToolUse JSON payload on
#     stdin.  Only `gh` and `git` are substituted, as PATH-shadowing stubs
#     (same convention as ci_watch_once.bats): the suite must never touch the
#     network and must never depend on the checkout's real branch.
#   - CLAUDE_NOTIFY_TMP_DIR redirects the hook's fail-open log into
#     BATS_TEST_TMPDIR, so a live hook's real log is never read or written.
#   - The KEY/SLUG the assertions expect are recomputed through the SHIPPED
#     helpers in scripts/_notify.sh, never hardcoded, so the test cannot drift
#     from the paths the watcher really creates.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does
# not fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

HOOK="${BATS_TEST_DIRNAME}/../scripts/post_tool_use__ci_watch_trigger.sh"
NOTIFY_SH="${BATS_TEST_DIRNAME}/../scripts/_notify.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    HOOK_LOG="$BATS_TEST_TMPDIR/ci_watch2_hook.log"

    # Short enough that the fail-open timeout test finishes in ~1s, long enough
    # that a loaded machine never trips it on a healthy stub.
    export CI_WATCH_HOOK_TIMEOUT=2

    # The directory the payload's `cwd` points at. The hook cd's into it before
    # calling git/gh; it does not have to be a real repo, because both are
    # stubbed.
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"

    BRANCH="feat-x"

    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    GIT_STUB_DIR="$BATS_TEST_TMPDIR/gitstub"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$GH_STUB_DIR" "$GIT_STUB_DIR" "$BIN"
    export GH_STUB_DIR GIT_STUB_DIR
    write_gh_stub
    write_git_stub
    export PATH="$BIN:$PATH"

    # Sourced BEFORE the first set_branch: that helper recomputes KEY/SLUG
    # through these same shipped functions.
    # shellcheck source=../scripts/_notify.sh
    source "$NOTIFY_SH"

    # The happy-path answers every test starts from; individual tests override
    # the one fixture they are about.
    set_branch "$BRANCH"
    gh_stub repo_name 0 "o/r"
    gh_stub pr_state 0 "OPEN"
}

# --- assertion helpers ------------------------------------------------------

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in (*"$1"*) ;; (*) return 0 ;; esac
    printf 'expected NOT to contain: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

# --- stubs ------------------------------------------------------------------

# Write one stubbed answer. Args: <key> <exit code|HANG> <stdout lines...>.
gh_stub() {
    local key="$1" rc="$2"
    shift 2
    { printf '%s\n' "$rc"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } >"$GH_STUB_DIR/$key"
    return 0
}

# The branch `git branch --show-current` reports, and the KEY/SLUG that go with
# it. Args: <branch> [exit code|HANG].
set_branch() {
    local b="$1" rc="${2:-0}"
    { printf '%s\n' "$rc"; [ -n "$b" ] && printf '%s\n' "$b"; } >"$GIT_STUB_DIR/branch"
    BRANCH="$b"
    KEY=$(_ci_watch_key "o/r" "$b" 2>/dev/null)
    SLUG=$(_ci_slug "$b")
    return 0
}

# Both stubs share one fixture format: line 1 is the exit code (or the literal
# HANG, which sleeps far past any time box so the hook's own watchdog is what
# ends the call), the rest is stdout.
write_gh_stub() {
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
key=""
case "$1 $2" in
    "repo view") key=repo_name ;;
    "pr view")   key=pr_state ;;
esac
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls.log"
[ -n "$key" ] || { echo "gh stub: unroutable call: $*" >&2; exit 99; }
f="$GH_STUB_DIR/$key"
[ -f "$f" ] || { echo "gh stub: no fixture for $key: $*" >&2; exit 99; }
rc=$(head -n 1 "$f")
[ "$rc" = "HANG" ] && { sleep 30; exit 0; }
tail -n +2 "$f"
exit "$rc"
STUB
    chmod +x "$BIN/gh"
}

write_git_stub() {
    cat >"$BIN/git" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GIT_STUB_DIR/calls.log"
[ "$1 $2" = "branch --show-current" ] || exit 1
f="$GIT_STUB_DIR/branch"
[ -f "$f" ] || exit 1
rc=$(head -n 1 "$f")
[ "$rc" = "HANG" ] && { sleep 30; exit 0; }
tail -n +2 "$f"
exit "$rc"
STUB
    chmod +x "$BIN/git"
}

# --- driving the hook -------------------------------------------------------

# Feed the hook one PostToolUse payload.
# Args: <command> [exit code] [tool stdout] [tool stderr] [tool name]
fire() {
    local cmd="$1" ec="${2:-0}" so="${3:-}" se="${4:-}" tn="${5:-Bash}"
    jq -nc --arg t "$tn" --arg c "$cmd" --arg cwd "$REPO" \
        --argjson ec "$ec" --arg so "$so" --arg se "$se" \
        '{tool_name:$t,cwd:$cwd,tool_input:{command:$c},
          tool_response:{exit_code:$ec,stdout:$so,stderr:$se}}' \
        | bash "$HOOK"
}

# The additionalContext the hook emitted, or "" when it did not trigger.
ctx() {
    local out
    out=$(fire "$@") || return "$?"
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

# A trigger must name the right mode and carry the exact background-launch
# phrasing. Args: <mode> <context text>.
# shellcheck disable=SC2016  # The backticks below are LITERAL text the hook
# emits for the agent to read — expanding them here would defeat the point of
# the assertion.
assert_launch_instruction() {
    local kind="$1" text="$2"
    assert_contains "bash ~/.claude/scripts/ci_watch_once.sh ${kind} '${BRANCH}'" "$text" || return 1
    assert_contains '`run_in_background: true`' "$text" || return 1
    assert_contains 'no explicit `timeout` override' "$text" || return 1
    return 0
}

# --- the exit-code-0 gate ---------------------------------------------------

@test "a FAILED git push never triggers, however well its text matches" {
    run ctx "git push" 1
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a FAILED gh pr create never triggers" {
    run ctx "gh pr create" 1
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a FAILED gh pr merge never triggers" {
    run ctx "gh pr merge --auto" 128
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

# --- the --help / -h exclusion ----------------------------------------------

@test "gh pr merge --help does not trigger even though it exits 0" {
    run ctx "gh pr merge --help"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr create -h does not trigger" {
    run ctx "gh pr create -h"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "git push --help does not trigger" {
    run ctx "git push --help"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "-h is matched as a FLAG, not a substring: a 'push-harder' branch still triggers" {
    set_branch "push-harder"
    run ctx "git push origin push-harder"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "a branch whose name ends in --help-ish text still triggers" {
    set_branch "fix-the--help-text"
    run ctx "git push origin fix-the--help-text"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

# --- the no-op push exclusion -----------------------------------------------

@test "a push reporting 'Everything up-to-date' on stdout does not trigger" {
    run ctx "git push" 0 "Everything up-to-date"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a push reporting 'Everything up-to-date' on stderr does not trigger" {
    run ctx "git push" 0 "" "Everything up-to-date"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

# --- the branch-delete exclusion --------------------------------------------

@test "git push --delete does not trigger" {
    run ctx "git push --delete origin feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "git push -d does not trigger" {
    run ctx "git push -d origin feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a :-prefixed deletion refspec does not trigger, even for the current branch" {
    run ctx "git push origin :feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

# --- the narrowed positive shapes -------------------------------------------

@test "a plain git push with an OPEN PR launches a push watcher" {
    run ctx "git push"
    assert_eq 0 "$status"
    assert_contains "A \`git push\` to 'feat-x' with an open PR just succeeded." "$output"
    assert_launch_instruction push "$output"
}

@test "git push -f launches a push watcher" {
    run ctx "git push -f"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "git push --force-with-lease launches a push watcher" {
    run ctx "git push --force-with-lease"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "git push origin <currentbranch> launches a push watcher" {
    run ctx "git push origin feat-x"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr create launches a PUSH watcher, with no gh pr view precheck" {
    run ctx "gh pr create"
    assert_eq 0 "$status"
    assert_contains "A \`gh pr create\` for 'feat-x' just succeeded" "$output"
    assert_launch_instruction push "$output"
    # The PR was just created, so its state needs no lookup. No gh call at
    # all happens on this path, so calls.log is never even created.
    assert_not_contains "pr view" "$(cat "$GH_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "gh pr create --head <currentbranch> with decorating flags launches a push watcher" {
    run ctx "gh pr create --head feat-x --title Fix --draft"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr merge launches a MERGE watcher with the merge task-id filename" {
    run ctx "gh pr merge"
    assert_eq 0 "$status"
    assert_contains "A \`gh pr merge\` of 'feat-x' just succeeded." "$output"
    assert_launch_instruction merge "$output"
}

@test "gh pr merge --auto launches a merge watcher" {
    run ctx "gh pr merge --auto --squash --delete-branch"
    assert_eq 0 "$status"
    assert_launch_instruction merge "$output"
}

@test "a merge trigger never runs the gh pr view OPEN precheck" {
    run ctx "gh pr merge --auto"
    assert_eq 0 "$status"
    # No gh call at all happens on this path, so calls.log is never created.
    assert_not_contains "pr view" "$(cat "$GH_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "the hook emits additionalContext ONLY — never a systemMessage" {
    run fire "git push"
    assert_eq 0 "$status"
    assert_not_contains "systemMessage" "$output"
    # Through a file, never an interpolated string: the payload contains single
    # quotes of its own.
    printf '%s' "$output" >"$BATS_TEST_TMPDIR/out.json"
    run jq -r 'keys | join(",")' "$BATS_TEST_TMPDIR/out.json"
    assert_eq "hookSpecificOutput" "$output"
    run jq -r '.hookSpecificOutput.hookEventName' "$BATS_TEST_TMPDIR/out.json"
    assert_eq "PostToolUse" "$output"
}

# --- out-of-scope shapes: no trigger, no guessing ---------------------------

@test "git push -C otherdir does not trigger" {
    run ctx "git push -C otherdir"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "git -C otherdir push does not trigger" {
    run ctx "git -C otherdir push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "git push origin someotherbranch does not trigger" {
    run ctx "git push origin someotherbranch"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "git push origin :branch-to-delete does not trigger" {
    run ctx "git push origin :branch-to-delete"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a multi-ref push does not trigger" {
    run ctx "git push origin feat-x other-branch"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a src:dst refspec push does not trigger" {
    run ctx "git push origin feat-x:feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a push to an explicit remote URL does not trigger" {
    run ctx "git push git@github.com:owner/other.git feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr create --repo owner/other does not trigger" {
    run ctx "gh pr create --repo owner/other"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr create -R owner/other does not trigger" {
    run ctx "gh pr create -R owner/other --title Fix"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr create --head <otherbranch> does not trigger" {
    run ctx "gh pr create --head some-other-branch"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr merge 123 --repo owner/other does not trigger" {
    run ctx "gh pr merge 123 --repo owner/other"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr merge with an explicit PR number does not trigger" {
    run ctx "gh pr merge 123 --auto"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr merge with an explicit PR URL does not trigger" {
    run ctx "gh pr merge https://github.com/owner/other/pull/9"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a compound command containing a push does not trigger" {
    run ctx "cd /elsewhere && git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a piped command containing a push does not trigger" {
    run ctx "git push | tee /tmp/log"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a non-Bash tool call never triggers" {
    run ctx "git push" 0 "" "" "Write"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "an unrelated Bash command never triggers" {
    run ctx "git status"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

# --- the OPEN-PR precheck ---------------------------------------------------

@test "a push whose PR is MERGED does not trigger" {
    gh_stub pr_state 0 "MERGED"
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a push whose PR is CLOSED does not trigger" {
    gh_stub pr_state 0 "CLOSED"
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a push on a branch with NO PR does not trigger, and is logged" {
    gh_stub pr_state 1 "no pull requests found for branch"
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "gh pr view failed" "$output"
}

# --- fail-open --------------------------------------------------------------

@test "a hanging gh pr view fails OPEN: no trigger, exit 0, one log line" {
    gh_stub pr_state HANG
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "gh pr view failed" "$output"
}

@test "an unresolvable current branch fails OPEN" {
    set_branch "" 1
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "could not resolve the current branch" "$output"
}

@test "a hanging git branch --show-current fails OPEN" {
    set_branch "feat-x" HANG
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "could not resolve the current branch" "$output"
}

@test "a cwd that does not exist fails OPEN" {
    REPO="$BATS_TEST_TMPDIR/gone"
    run ctx "git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "cwd does not exist" "$output"
}
