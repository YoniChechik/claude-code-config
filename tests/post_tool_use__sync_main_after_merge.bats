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
