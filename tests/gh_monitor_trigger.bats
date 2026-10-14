#!/usr/bin/env bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/post_tool_use__gh_monitor_trigger.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    LEDGER="$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl"
    HOOK_LOG="$BATS_TEST_TMPDIR/hooks.log"

    export GH_MONITOR_HOOK_TIMEOUT=5

    REPO="$BATS_TEST_TMPDIR/repo"
    W="$BATS_TEST_TMPDIR/w"
    mkdir -p "$REPO" "$W"

    BRANCH="feat-x"

    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    GIT_STUB_DIR="$BATS_TEST_TMPDIR/gitstub"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$GH_STUB_DIR" "$GIT_STUB_DIR" "$BIN"
    export GH_STUB_DIR GIT_STUB_DIR
    write_gh_stub
    write_git_stub
    export PATH="$BIN:$PATH"

    set_branch "$BRANCH"
    gh_stub repo_name 0 "o/r"
    gh_stub pr_state 0 "OPEN"
    gh_stub pr_ident 0 $'12\thttps://github.com/o/r/pull/12'

    MON_CALLS="$BATS_TEST_TMPDIR/monitor_calls.log"
    export MON_CALLS
    export GH_MONITOR_SCRIPT="$BIN/fake_gh_monitor.sh"
    cat >"$GH_MONITOR_SCRIPT" <<'MON'
#!/bin/bash
printf '%s|session=%s|cwd=%s\n' "$*" "${CLAUDE_CODE_SESSION_ID:-}" "$PWD" >>"$MON_CALLS"
[ -n "${FAKE_MONITOR_FAIL:-}" ] && exit 1
target=$2
repo=o/r
[ "$3" = --repo ] && repo=$4
meta="$CLAUDE_NOTIFY_TMP_DIR/gh_monitor_watch_merge_${target//[^A-Za-z0-9]/_}.meta"
printf 'session=%s\ntarget=%s\nrepo=%s\nresult=%s\nwait_cmd=bash /x/gh_monitor.sh wait %s --repo %s\n' \
    "${CLAUDE_CODE_SESSION_ID:-}" "$target" "$repo" "$meta.result" "$target" "$repo" >"$meta"
printf '%s\n' "$meta"
MON
    chmod +x "$GH_MONITOR_SCRIPT"
}

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

gh_stub() {
    local key="$1" rc="$2"
    shift 2
    { printf '%s\n' "$rc"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } >"$GH_STUB_DIR/$key"
    return 0
}

set_branch() {
    local b="$1" rc="${2:-0}"
    { printf '%s\n' "$rc"; [ -n "$b" ] && printf '%s\n' "$b"; } >"$GIT_STUB_DIR/branch"
    BRANCH="$b"
    return 0
}

write_gh_stub() {
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
key=""
case "$1 $2" in
    "repo view") key=repo_name ;;
    "pr view")   key=pr_state ;;
esac
case "$*" in (*mergeCommit*) key=pr_info ;; (*number,url*) key=pr_ident ;; esac
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
case "$*" in
    "branch --show-current") f="$GIT_STUB_DIR/branch" ;;
    "rev-parse HEAD @{push}") f="$GIT_STUB_DIR/heads" ;;
    *) f="$GIT_STUB_DIR/x_$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_')" ;;
esac
[ -f "$f" ] || exit 1
rc=$(head -n 1 "$f")
[ "$rc" = "HANG" ] && { sleep 30; exit 0; }
tail -n +2 "$f"
exit "$rc"
STUB
    chmod +x "$BIN/git"
}

fire() {
    local cmd="$1" ec="${2:-0}" so="${3:-}" se="${4:-}" tn="${5:-Bash}"
    jq -nc --arg t "$tn" --arg c "$cmd" --arg cwd "$REPO" \
        --argjson ec "$ec" --arg so "$so" --arg se "$se" --arg aid "${FIRE_AGENT_ID:-}" \
        --arg pid "${FIRE_PROMPT_ID:-}" \
        '{session_id:"s1",tool_name:$t,cwd:$cwd,tool_input:{command:$c},
          tool_response:{exit_code:$ec,stdout:$so,stderr:$se}}
         + (if $aid == "" then {} else {agent_id:$aid} end)
         + (if $pid == "" then {} else {prompt_id:$pid} end)' \
        | bash "$HOOK"
}

ctx() {
    local out
    out=$(fire "$@") || return "$?"
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

# shellcheck disable=SC2016
assert_launch_instruction() {
    local kind="$1" text="$2" selector="${3:-$BRANCH}" repo="${4:-}"
    local expect="bash ~/.claude/scripts/gh_monitor.sh ${kind} '${selector}'"
    [ -n "$repo" ] && expect="${expect} --repo '${repo}'"
    assert_contains "$expect" "$text" || return 1
    assert_contains '`run_in_background: true`' "$text" || return 1
    assert_contains 'no explicit `timeout` override' "$text" || return 1
    return 0
}

assert_merge_spawned() {
    local text="$1" selector="${2:-$BRANCH}" repo="${3:-}"
    local expect="merge ${selector}"
    [ -n "$repo" ] && expect="${expect} --repo ${repo}"
    expect="${expect} --detach|session=s1"
    assert_contains "$expect" "$(cat "$MON_CALLS" 2>/dev/null)" || return 1
    assert_contains "detached post-merge watcher is ALREADY running" "$text" || return 1
    assert_contains "Do NOT start \`gh_monitor.sh merge\` yourself" "$text" || return 1
    assert_contains "bash /x/gh_monitor.sh wait ${selector} --repo ${repo:-o/r}" "$text" || return 1
    assert_contains '`run_in_background: true`' "$text" || return 1
    assert_contains "the PR number and what it is about, the merge commit sha, and each workflow's conclusion" "$text" || return 1
    return 0
}

@test "merge spawns exactly one detached watcher in the command's cwd and marks it announced for the main session" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 3951 --squash"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "3951"
    assert_eq 1 "$(grep -c . "$MON_CALLS")"
    assert_contains "cwd=$REPO" "$(cat "$MON_CALLS")"
    assert_contains "Its deploy is NOT verified yet: do not tell the user that it is deployed, shipped or live until the verdict arrives" "$output"
    [ -e "$BATS_TEST_TMPDIR/gh_monitor_watch_merge_3951.meta.announced" ] \
        || { echo "main-session merge should be marked announced" >&2; return 1; }
    assert_not_contains "SendMessage" "$output"
    assert_not_contains "You are a subagent" "$output"
}

@test "a subagent merge whose PR details cannot be read still orders the SendMessage with the selector and the wait command" {
    gh_stub pr_state 0 "MERGED"
    FIRE_AGENT_ID=sub1 run ctx "gh pr merge feat-x --squash"
    assert_eq 0 "$status"
    assert_contains "IMMEDIATELY, before any other step, call the SendMessage tool with \`to: \"main\"\`" "$output"
    assert_contains "\"PR feat-x on o/r merged as a merge commit not known yet (the watcher's verdict names it). Main session: run the exact command \`bash /x/gh_monitor.sh wait feat-x --repo o/r\`" "$output"
    assert_contains "Your final report MUST contain this line verbatim" "$output"
}

@test "merge with --repo before the PR number spawns the watcher with both" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --repo sunsay-ltd/core 3951 --squash"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "3951" "sunsay-ltd/core"
    assert_contains "pr view 3951 --repo sunsay-ltd/core" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "a subagent merge spawns the watcher, tells the subagent not to wait, and leaves it unannounced for the main session" {
    gh_stub pr_state 0 "MERGED"
    gh_stub pr_info 0 $'3951\tabc1234def5678\tfeat: add "thing"'
    FIRE_AGENT_ID=sub1 run ctx "cd /tmp && rtk gh pr merge 3951 --repo sunsay-ltd/core --squash --delete-branch 2>&1 | tail -3"
    assert_eq 0 "$status"
    assert_contains "pr view 3951 --repo sunsay-ltd/core --json number,title,mergeCommit" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "IMMEDIATELY, before any other step, call the SendMessage tool with \`to: \"main\"\` and this message: \"PR 3951 (feat: add 'thing') on sunsay-ltd/core merged as abc1234def5678. Main session: run the exact command \`bash /x/gh_monitor.sh wait 3951 --repo sunsay-ltd/core\` with \`run_in_background: true\`, and do not report it deployed until it returns a verdict.\"" "$output"
    assert_contains "merge 3951 --repo sunsay-ltd/core --detach|session=s1" "$(cat "$MON_CALLS")"
    assert_contains "You are a subagent: do not wait for the deploys" "$output"
    assert_contains "never say they passed" "$output"
    assert_contains "Your final report MUST contain this line verbatim" "$output"
    assert_contains "PR '3951' on sunsay-ltd/core is merged; its deploy is NOT verified yet. Main session: run \`bash /x/gh_monitor.sh wait 3951 --repo sunsay-ltd/core\` with \`run_in_background: true\` and wait for its verdict before reporting it deployed." "$output"
    [ ! -e "$BATS_TEST_TMPDIR/gh_monitor_watch_merge_3951.meta.announced" ] \
        || { echo "a subagent merge must stay unannounced" >&2; return 1; }
}

@test "if the detached watcher cannot be spawned the agent is told to start it itself" {
    gh_stub pr_state 0 "MERGED"
    FAKE_MONITOR_FAIL=1 run ctx "gh pr merge 3951 --repo sunsay-ltd/core"
    assert_eq 0 "$status"
    assert_contains "could not be started" "$output"
    assert_contains "bash ~/.claude/scripts/gh_monitor.sh merge '3951' --repo 'sunsay-ltd/core'" "$output"
    assert_contains '`run_in_background: true`' "$output"
    assert_contains "spawn failed: merge 3951" "$(cat "$HOOK_LOG")"
}

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

@test "a FAILED gh pr merge whose PR is still OPEN does not trigger" {
    gh_stub pr_state 0 "OPEN"
    run ctx "gh pr merge --auto" 128
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a gh pr merge that exits nonzero but IS really merged still triggers" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --squash --delete-branch" 1
    assert_eq 0 "$status"
    assert_merge_spawned "$output"
}

@test "a gh pr merge with an explicit target that exits nonzero but IS really merged still triggers" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 456 --repo sunsay-ltd/core --squash --delete-branch" 1
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "456" "sunsay-ltd/core"
}

@test "a merge precheck failure (gh pr view itself fails) does not trigger and is logged" {
    gh_stub pr_state 1 "no pull requests found"
    run ctx "gh pr merge --squash --delete-branch" 1
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "gh pr view failed" "$output"
}

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
    assert_not_contains "pr view" "$(cat "$GH_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "gh pr create --head <currentbranch> with decorating flags launches a push watcher" {
    run ctx "gh pr create --head feat-x --title Fix --draft"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr create with a multi-word quoted --title still launches a push watcher" {
    run ctx 'gh pr create --title "feat(x): flip five flags on production" --body-file /tmp/body.md'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr create with a multi-word quoted --body still launches a push watcher" {
    run ctx 'gh pr create --title Fix --body "line one and line two"'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr create with a heredoc --body (quoted delimiter) still launches a push watcher" {
    run ctx 'gh pr create --title Fix --body "$(cat <<'"'"'EOF'"'"'
Some body text; with a semicolon and | a pipe and > a redirect char, all literal inside the heredoc.
EOF
)"'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "gh pr create with a heredoc --body (UNQUOTED delimiter) launches a push watcher" {
    run ctx 'gh pr create --title Fix --body "$(cat <<EOF
some body text
EOF
)"'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "a heredoc --body followed by a real dangerous command still stays out of contract" {
    run ctx 'gh pr create --title Fix --body "$(cat <<'"'"'EOF'"'"'
safe body
EOF
)" ; rm -rf /'
    assert_eq 0 "$status"
    [ -z "$output" ]
}

@test "gh pr merge launches a MERGE watcher with the merge task-id filename" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge"
    assert_eq 0 "$status"
    assert_contains "A \`gh pr merge\` of 'feat-x' on o/r just succeeded." "$output"
    assert_merge_spawned "$output"
}

@test "gh pr merge --auto launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --auto --squash --delete-branch"
    assert_eq 0 "$status"
    assert_merge_spawned "$output"
}

@test "gh pr merge with a multi-word quoted --body still launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx 'gh pr merge --auto --body "merging after two rounds of review"'
    assert_eq 0 "$status"
    assert_merge_spawned "$output"
}

@test "a merge trigger DOES run a gh pr view MERGED precheck, unlike push's OPEN precheck" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --auto"
    assert_eq 0 "$status"
    assert_contains "pr view" "$(cat "$GH_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "the hook emits additionalContext ONLY — never a systemMessage" {
    run fire "git push"
    assert_eq 0 "$status"
    assert_not_contains "systemMessage" "$output"
    printf '%s' "$output" >"$BATS_TEST_TMPDIR/out.json"
    run jq -r 'keys | join(",")' "$BATS_TEST_TMPDIR/out.json"
    assert_eq "hookSpecificOutput" "$output"
    run jq -r '.hookSpecificOutput.hookEventName' "$BATS_TEST_TMPDIR/out.json"
    assert_eq "PostToolUse" "$output"
}

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

@test "gh pr create --repo owner/other trusts the explicit repo and launches a push watcher" {
    run ctx "gh pr create --repo owner/other"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output" "$BRANCH" "owner/other"
}

@test "gh pr create -R owner/other trusts the explicit repo and launches a push watcher" {
    run ctx "gh pr create -R owner/other --title Fix"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output" "$BRANCH" "owner/other"
}

@test "gh pr create --head <otherbranch> does not trigger" {
    run ctx "gh pr create --head some-other-branch"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "gh pr merge 123 --repo owner/other trusts both explicit values and launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 123 --repo owner/other"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "123" "owner/other"
    assert_not_contains "branch --show-current" "$(cat "$GIT_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "gh pr merge with an explicit PR number trusts it and launches a merge watcher, no cwd branch lookup" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 123 --auto"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "123"
    assert_not_contains "branch --show-current" "$(cat "$GIT_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "gh pr merge with an explicit PR URL trusts it and launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge https://github.com/owner/other/pull/9"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "https://github.com/owner/other/pull/9"
}

@test "gh pr merge <number> --repo owner/repo --squash launches a merge watcher with the explicit number and repo" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 456 --repo sunsay-ltd/core --squash"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "456" "sunsay-ltd/core"
}

@test "gh pr merge --repo owner/other with NO explicit PR number falls back to the cwd branch as selector" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --repo owner/other --auto"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "$BRANCH" "owner/other"
    assert_contains "branch --show-current" "$(cat "$GIT_STUB_DIR/calls.log" 2>/dev/null || true)"
}

@test "a merge with no explicit target and an unresolvable cwd branch fails OPEN" {
    set_branch "" 1
    run ctx "gh pr merge --auto"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "could not resolve the current branch" "$output"
}

@test "gh pr merge with two positionals stays out of contract" {
    run ctx "gh pr merge 123 456"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "an rtk-rewritten gh pr merge still launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "rtk gh pr merge 456 --repo sunsay-ltd/core --squash --delete-branch"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "456" "sunsay-ltd/core"
}

@test "an rtk-rewritten gh pr create still launches a push watcher" {
    run ctx "rtk gh pr create --title Fix --body-file /tmp/body.md"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "an rtk-rewritten git push still launches a push watcher" {
    run ctx "rtk git push"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "rtk proxy <cmd> unwraps one level deeper and still launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "rtk proxy gh pr merge 456 --repo sunsay-ltd/core --squash"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "456" "sunsay-ltd/core"
}

@test "rtk run <cmd> unwraps one level deeper and still launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "rtk run gh pr merge --auto"
    assert_eq 0 "$status"
    assert_merge_spawned "$output"
}

@test "bare rtk with no further command stays out of contract" {
    run ctx "rtk"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "an rtk-rewritten FAILED gh pr merge still never triggers (exit-code gate still applies)" {
    run ctx "rtk gh pr merge --auto" 1
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a compound push into a directory that does not exist does not trigger, and is logged" {
    run ctx "cd /elsewhere-that-does-not-exist && git push"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "cwd does not exist: /elsewhere-that-does-not-exist" "$output"
}

@test "cd W && git push launches a push watcher for W's branch" {
    run ctx "cd $W && git push"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "git -C W push launches a push watcher" {
    run ctx "git -C $W push"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "a piped push without HEAD == @{push} evidence does not trigger, and is logged" {
    run ctx "git push | tee /tmp/log"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "HEAD != @{push}" "$output"
}

@test "a piped push whose HEAD matches @{push} launches a push watcher" {
    printf '0\nabc123\nabc123\n' >"$GIT_STUB_DIR/heads"
    run ctx "git push -u origin HEAD 2>&1 | tail -20"
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
}

@test "a piped push whose HEAD differs from @{push} does not trigger" {
    printf '0\nabc123\ndef456\n' >"$GIT_STUB_DIR/heads"
    run ctx "git push 2>&1 | tail -2; git log --oneline -1"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "cd W && gh pr create ... 2>&1 | tail -3 launches a push watcher from the PR URL in stdout" {
    run ctx 'cd '"$W"' && gh pr create --title "feat(x): a b" --body "$(cat <<'"'"'EOF'"'"'
- a | b; c && d
EOF
)" 2>&1 | tail -3' 0 "https://github.com/o/r/pull/42"
    assert_eq 0 "$status"
    assert_contains "A \`gh pr create\` for 'feat-x' just succeeded" "$output"
    assert_launch_instruction push "$output" "$BRANCH" "o/r"
}

@test "a failed gh pr create piped to tail does not trigger, and is logged" {
    run ctx 'cd '"$W"' && gh pr create --title t --body b 2>&1 | tail -3' 0 "pull request create failed: GraphQL: No commits between main and feat-x"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "create: exit code not attributable and no PR URL in the output" "$output"
}

@test "a gh pr create that reports an already-existing PR does not trigger" {
    run ctx 'gh pr create --fill 2>&1 | tail -3' 0 "a pull request for branch \"feat-x\" into branch \"main\" already exists:
https://github.com/o/r/pull/7"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a piped push followed by gh pr create yields exactly one push watcher" {
    printf '0\nabc\nabc\n' >"$GIT_STUB_DIR/heads"
    run ctx 'git push -u origin HEAD 2>&1 | tail -2; gh pr create --title a --body "$(cat <<'"'"'EOF'"'"'
x
EOF
)"'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
    run grep -o "gh_monitor.sh push" <<<"$output"
    assert_eq 1 "${#lines[@]}"
}

@test "gh pr merge piped to tail then followed by gh pr view still launches a merge watcher" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 3644 --squash 2>&1 | tail -5; echo ---; gh pr view 3644 --json state"
    assert_eq 0 "$status"
    assert_merge_spawned "$output" "3644"
}

@test "git push inside a quoted heredoc commit message is not a push; the real one triggers once" {
    run ctx 'git add . && git commit -F - <<'"'"'EOF'"'"'
msg; git push
EOF
git push'
    assert_eq 0 "$status"
    assert_launch_instruction push "$output"
    run grep -o "gh_monitor.sh push" <<<"$output"
    assert_eq 1 "${#lines[@]}"
}

@test "gh pr merge mentioned inside a commit message does not trigger" {
    gh_stub pr_state 0 "MERGED"
    run ctx 'git commit -m "fix: mention gh pr merge here" && echo ok'
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "a backgrounded push does not trigger, and is logged" {
    run ctx "git push origin feat-x &"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    run cat "$HOOK_LOG"
    assert_contains "push: backgrounded" "$output"
}

log_lines() {
    [ -f "$HOOK_LOG" ] || { echo 0; return; }
    grep -c '' "$HOOK_LOG"
}

@test "every skipped real candidate writes exactly one skip line" {
    local before after cmd
    for cmd in "git push --help" "git push" "git push --delete origin feat-x" "gh pr merge 1 2" "gh pr create --head other"; do
        before=$(log_lines)
        case "$cmd" in "git push") fire "$cmd" 1 >/dev/null ;; *) fire "$cmd" >/dev/null ;; esac
        after=$(log_lines)
        assert_eq $((before + 1)) "$after" || { echo "cmd: $cmd" >&2; return 1; }
        tail -1 "$HOOK_LOG" | grep -q " skip: " || { echo "no skip line for: $cmd" >&2; return 1; }
    done
}

@test "non-candidates write no log line" {
    local cmd
    for cmd in "ls -la" "git status" "echo \"git push\" | tee log" "git commit -m 'run gh pr merge later'" "rtk"; do
        fire "$cmd" >/dev/null
        [ ! -s "$HOOK_LOG" ] || { echo "logged for: $cmd" >&2; cat "$HOOK_LOG" >&2; return 1; }
    done
    fire "git push" 0 "" "" "Write" >/dev/null
    [ ! -s "$HOOK_LOG" ]
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

git_stub_cmd() {
    local key rc="$2"
    key="x_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
    shift 2
    { printf '%s\n' "$rc"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } >"$GIT_STUB_DIR/$key"
}

@test "a confirmed merge appends a merge record to the session ledger with the waiter command and prompt id" {
    gh_stub pr_state 0 "MERGED"
    FIRE_PROMPT_ID=p-1 run ctx "gh pr merge 3951 --squash"
    assert_eq 0 "$status"
    assert_eq 1 "$(jq -s 'length' "$LEDGER")"
    assert_eq merge "$(jq -r .kind "$LEDGER")"
    assert_eq o/r "$(jq -r .repo "$LEDGER")"
    assert_eq 3951 "$(jq -r .target "$LEDGER")"
    assert_eq p-1 "$(jq -r .prompt_id "$LEDGER")"
    assert_eq "bash /x/gh_monitor.sh wait 3951 --repo o/r" "$(jq -r .wait_cmd "$LEDGER")"
    [[ $(jq -r .ts "$LEDGER") =~ ^[0-9]+$ ]]
    assert_eq 700 "$(stat -f %Lp "$CLAUDE_STATE_DIR/sessions/s1")"
    assert_eq 600 "$(stat -f %Lp "$LEDGER")"
}

@test "a merge by branch name records the resolved PR number, so the verify record can match it" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge --squash"
    assert_eq 0 "$status"
    assert_eq feat-x "$(jq -r .target "$LEDGER")"
    assert_eq 12 "$(jq -r .pr "$LEDGER")"
    assert_eq o/r "$(jq -r .repo "$LEDGER")"
}

@test "a merge whose watcher fails to spawn records the repo resolved from the PR url" {
    gh_stub pr_state 0 "MERGED"
    gh_stub pr_ident 0 $'12\thttps://github.com/acme/app/pull/12'
    FAKE_MONITOR_FAIL=1 run ctx "gh pr merge --squash"
    assert_eq 0 "$status"
    assert_contains "watcher could not be started" "$output"
    assert_eq acme/app "$(jq -r .repo "$LEDGER")"
    assert_eq 12 "$(jq -r .pr "$LEDGER")"
    assert_eq "" "$(jq -r .wait_cmd "$LEDGER")"
}

@test "a merge whose PR number cannot be resolved is still recorded and logged loudly" {
    gh_stub pr_state 0 "MERGED"
    gh_stub pr_ident 1
    run ctx "gh pr merge 3951 --squash"
    assert_eq 0 "$status"
    assert_eq merge "$(jq -r .kind "$LEDGER")"
    assert_eq "" "$(jq -r .pr "$LEDGER")"
    assert_contains "error: merge: cannot resolve the PR number and repo of 3951" "$(cat "$HOOK_LOG")"
}

@test "a merge without a prompt id records no prompt_id field" {
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 3951 --squash"
    assert_eq null "$(jq -r .prompt_id "$LEDGER")"
}

@test "a subagent merge is recorded in the ledger with its agent id" {
    gh_stub pr_state 0 "MERGED"
    gh_stub pr_info 0 "3951	abc1234	t"
    FIRE_AGENT_ID=sub9 run ctx "gh pr merge 3951 --squash"
    assert_eq sub9 "$(jq -r .agent_id "$LEDGER")"
    assert_eq merge "$(jq -r .kind "$LEDGER")"
}

@test "a merge whose PR is still open records nothing" {
    gh_stub pr_state 0 "OPEN"
    run ctx "gh pr merge 3951 --squash" 1
    [ ! -s "$LEDGER" ]
}

@test "a push to the default branch records a push event and starts no watcher" {
    set_branch main
    printf '0\nabc\nabc\n' >"$GIT_STUB_DIR/heads"
    git_stub_cmd "symbolic-ref --quiet --short refs/remotes/origin/HEAD" 0 origin/main
    git_stub_cmd "remote get-url origin" 0 git@github.com:o/claude-config.git
    git_stub_cmd "rev-parse HEAD" 0 abc
    run ctx "git push" 0
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_eq push "$(jq -r .kind "$LEDGER")"
    assert_eq o/claude-config "$(jq -r .repo "$LEDGER")"
    assert_eq main "$(jq -r .branch "$LEDGER")"
    assert_eq abc "$(jq -r .sha "$LEDGER")"
    [ ! -s "$MON_CALLS" ]
}

@test "a push of a feature branch records nothing in the ledger" {
    printf '0\nabc\nabc\n' >"$GIT_STUB_DIR/heads"
    git_stub_cmd "symbolic-ref --quiet --short refs/remotes/origin/HEAD" 0 origin/main
    run ctx "git push" 0
    [ ! -e "$LEDGER" ]
}

@test "a symlinked state directory is never written through" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CLAUDE_STATE_DIR"
    gh_stub pr_state 0 "MERGED"
    run ctx "gh pr merge 3951 --squash"
    assert_eq 0 "$status"
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
    assert_contains "ledger: state untrusted" "$(cat "$HOOK_LOG")"
    assert_contains "watcher is ALREADY running" "$output"
}
