#!/usr/bin/env bats
#
# Tests for scripts/_git_sync.sh's _sync_primary_checkout_to_origin_main,
# shared by session_start.sh and post_tool_use__sync_main_after_merge.sh.
#
# Uses REAL git repos in BATS_TEST_TMPDIR rather than a PATH-shadowing stub:
# the function's whole job is real filesystem git state (branch, HEAD,
# working tree), which a stub would only re-describe, not verify.

LIB="${BATS_TEST_DIRNAME}/../scripts/_git_sync.sh"

setup() {
    source "$LIB"

    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    git init --quiet --bare -b main "$ORIGIN"

    PRIMARY="$BATS_TEST_TMPDIR/primary"
    git clone --quiet "$ORIGIN" "$PRIMARY"
    git -C "$PRIMARY" config user.email "t@example.com"
    git -C "$PRIMARY" config user.name "t"
    git -C "$PRIMARY" commit --quiet --allow-empty -m "initial"
    git -C "$PRIMARY" push --quiet origin main
}

@test "syncs the primary checkout to a new commit pushed to origin/main" {
    # Simulate a merge landing on origin from elsewhere: a second clone pushes
    # a new commit, while PRIMARY (this session's base checkout) never fetches
    # it on its own.
    OTHER="$BATS_TEST_TMPDIR/other"
    git clone --quiet "$ORIGIN" "$OTHER"
    git -C "$OTHER" config user.email "t@example.com"
    git -C "$OTHER" config user.name "t"
    git -C "$OTHER" commit --quiet --allow-empty -m "merged PR"
    git -C "$OTHER" push --quiet origin main

    _sync_primary_checkout_to_origin_main "$PRIMARY"

    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$(git -C "$OTHER" rev-parse HEAD)" ]
    [ "$(git -C "$PRIMARY" branch --show-current)" = "main" ]
}

@test "discards uncommitted local changes in the primary checkout" {
    echo "local edit nobody committed" >"$PRIMARY/scratch.txt"

    _sync_primary_checkout_to_origin_main "$PRIMARY"

    [ ! -e "$PRIMARY/scratch.txt" ]
    [ -z "$(git -C "$PRIMARY" status --porcelain)" ]
}

@test "does nothing when the primary checkout has no local main branch" {
    # A repo whose only branch is not "main" — checkout -f main must fail, and
    # the function must not fall through to reset/clean on whatever branch is
    # actually checked out.
    NOMAIN="$BATS_TEST_TMPDIR/nomain"
    git init --quiet -b trunk "$NOMAIN"
    git -C "$NOMAIN" config user.email "t@example.com"
    git -C "$NOMAIN" config user.name "t"
    git -C "$NOMAIN" commit --quiet --allow-empty -m "trunk commit"
    before="$(git -C "$NOMAIN" rev-parse HEAD)"

    _sync_primary_checkout_to_origin_main "$NOMAIN"

    [ "$(git -C "$NOMAIN" branch --show-current)" = "trunk" ]
    [ "$(git -C "$NOMAIN" rev-parse HEAD)" = "$before" ]
}

@test "never touches the caller's own cwd" {
    cwd_before="$PWD"
    _sync_primary_checkout_to_origin_main "$PRIMARY"
    [ "$PWD" = "$cwd_before" ]
}
