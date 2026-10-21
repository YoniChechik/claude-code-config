#!/usr/bin/env bats
#
# Tests for scripts/post_tool_use__sync_main_after_merge.sh — the
# PostToolUse:Bash hook that syncs the PRIMARY checkout to origin/main right
# after a `gh pr merge` succeeds.
#
# Uses REAL git repos (a bare "origin", a "primary" clone, and a linked
# worktree off primary) rather than a git stub: the hook's whole job is real
# git state across two directories (the worktree it runs from, and the
# primary checkout it syncs), which a stub would only re-describe. No `gh`
# stub is needed — this hook never calls `gh`, only `git`.

HOOK="${BATS_TEST_DIRNAME}/../scripts/post_tool_use__sync_main_after_merge.sh"

setup() {
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    HOOK_LOG="$CLAUDE_HOOK_LOG_DIR/hooks.log"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    git init --quiet --bare -b main "$ORIGIN"

    PRIMARY="$BATS_TEST_TMPDIR/primary"
    git clone --quiet "$ORIGIN" "$PRIMARY"
    git -C "$PRIMARY" config user.email "t@example.com"
    git -C "$PRIMARY" config user.name "t"
    git -C "$PRIMARY" commit --quiet --allow-empty -m "initial"
    git -C "$PRIMARY" push --quiet origin main

    WT="$BATS_TEST_TMPDIR/wt"
    git -C "$PRIMARY" worktree add --quiet -b feature-x "$WT" main

    # Simulate the merge this hook reacts to: land a new commit on origin the
    # same way a real `gh pr merge` would, from a throwaway third clone so
    # PRIMARY never sees it except through the hook's own sync.
    OTHER="$BATS_TEST_TMPDIR/other"
    git clone --quiet "$ORIGIN" "$OTHER"
    git -C "$OTHER" config user.email "t@example.com"
    git -C "$OTHER" config user.name "t"
    git -C "$OTHER" commit --quiet --allow-empty -m "merged PR"
    git -C "$OTHER" push --quiet origin main
    MERGED_SHA="$(git -C "$OTHER" rev-parse HEAD)"
}

# fire <command> <exit_code> <cwd> — builds the PostToolUse JSON payload and
# pipes it through the real hook.
fire() {
    local cmd="$1" exit_code="$2" cwd="$3" payload
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s},"cwd":%s}' \
        "$(printf '%s' "$cmd" | jq -Rs .)" "$exit_code" "$(printf '%s' "$cwd" | jq -Rs .)")
    printf '%s' "$payload" | bash "$HOOK"
}

@test "a successful gh pr merge syncs the primary checkout to origin/main" {
    run fire "gh pr merge 12 --squash --delete-branch" 0 "$WT"
    [ "$status" -eq 0 ]

    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
    [ "$(git -C "$PRIMARY" branch --show-current)" = "main" ]
}

@test "running from the primary checkout itself (not a worktree) still syncs" {
    run fire "gh pr merge 12" 0 "$PRIMARY"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
}

@test "an unrelated command never syncs" {
    before="$(git -C "$PRIMARY" rev-parse HEAD)"
    run fire "ls -la" 0 "$WT"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ]
}

@test "gh pr merge --help never syncs" {
    before="$(git -C "$PRIMARY" rev-parse HEAD)"
    run fire "gh pr merge --help" 0 "$WT"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ]
}

@test "a gh pr merge that exits nonzero still syncs (gh's own post-merge branch-switch can fail after a real merge)" {
    # Confirmed live, repeatedly, in this repo's own merge workflow:
    # `gh pr merge --squash --delete-branch` reliably exits 1 on its local
    # branch-switch step ("... already used by worktree ...") even when the
    # remote merge fully succeeded. There is no reliable way to tell that
    # case apart from a genuine failure using only the exit code, and an
    # extra sync after a real failure is harmless, so this hook must not
    # gate on exit code at all.
    run fire "gh pr merge 12 --squash --delete-branch" 1 "$WT"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
}

@test "gh pr merge mentioned inside a commit message never syncs and logs nothing" {
    before="$(git -C "$PRIMARY" rev-parse HEAD)"
    run fire 'git commit -m "docs: run gh pr merge 12 after review" && echo ok' 0 "$WT"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ]
    [ ! -s "$HOOK_LOG" ]
}

@test "cd into the worktree, merge and pipe to tail syncs from the cd target" {
    run fire "cd $WT && gh pr merge 1 --squash 2>&1 | tail -3" 0 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
    grep -q "sync: [^ ]*/primary " "$HOOK_LOG"
}

@test "a cwd outside any repo skips with a logged reason" {
    before="$(git -C "$PRIMARY" rev-parse HEAD)"
    run fire "gh pr merge 1" 0 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ]
    grep -q "skip: not a git repo: $BATS_TEST_TMPDIR" "$HOOK_LOG"
}

@test "an unrelated command logs nothing" {
    run fire "ls -la" 0 "$WT"
    [ "$status" -eq 0 ]
    [ ! -s "$HOOK_LOG" ]
}

@test "gh pr merge --help is a skipped candidate and is logged" {
    run fire "gh pr merge --help" 0 "$WT"
    [ "$status" -eq 0 ]
    grep -q "skip: no gh pr merge with a known directory and no help flag" "$HOOK_LOG"
}

@test "a non-Bash tool whose payload mentions gh pr merge logs nothing" {
    payload=$(jq -nc --arg cwd "$WT" '{tool_name:"Write",tool_input:{file_path:"/x",content:"gh pr merge 1"},cwd:$cwd}')
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -s "$HOOK_LOG" ]
}

wrap() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/gtimeout"
    chmod +x "$BATS_TEST_TMPDIR/bin/gtimeout"
    jq -nc --arg c "$1" '{tool_name:"Bash",tool_use_id:"toolu_1",tool_input:{command:$c}}' \
        | PATH="$BATS_TEST_TMPDIR/bin:$PATH" BASH_TIMEOUT_SKIP_RTK=1 bash "${BATS_TEST_DIRNAME}/../hooks/bash-timeout-pre.sh" \
        | jq -r '.hookSpecificOutput.updatedInput.command'
}

@test "a compound merge rewritten by the bash-timeout wrapper syncs" {
    wrapped=$(wrap "cd $WT && sha=\$(git rev-parse HEAD) && gh pr merge 164 --squash --match-head-commit \"\$sha\" 2>&1 | tail -2; gh pr view 164 --json state -q .state")
    [[ $wrapped == "bash '"*"/hooks/bash-timeout-run.sh' "* ]]
    run fire "$wrapped" 0 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
    grep -q "sync: [^ ]*/primary | cd $WT && sha=" "$HOOK_LOG"
}

@test "a wrapped merge whose command holds single quotes syncs" {
    wrapped=$(wrap "cd $WT && gh pr merge 5 --squash --subject 'it'\"'\"'s done' && echo 'ok'")
    run fire "$wrapped" 0 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
}

@test "a wrapped command that only mentions gh pr merge in a string never syncs" {
    before="$(git -C "$PRIMARY" rev-parse HEAD)"
    wrapped=$(wrap "cd $WT && echo 'gh pr merge 5'")
    run fire "$wrapped" 0 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ]
}

@test "a wrapped merge whose later step fails still syncs" {
    wrapped=$(wrap "cd $WT && gh pr merge 7 --squash && false")
    run fire "$wrapped" 1 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$MERGED_SHA" ]
}

@test "settings.json runs the sync hook for Bash on PostToolUse and on PostToolUseFailure" {
    for event in PostToolUse PostToolUseFailure; do
        run jq -e --arg e "$event" 'any(.hooks[$e][]; .matcher == "Bash" and any(.hooks[]; .command | endswith("/scripts/post_tool_use__sync_main_after_merge.sh")))' "${BATS_TEST_DIRNAME}/../settings.json"
        [ "$status" -eq 0 ]
    done
}
