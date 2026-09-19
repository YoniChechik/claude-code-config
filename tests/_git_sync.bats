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

# =============================================================================
# _cleanup_worktrees_and_branches — destructive by design (git worktree
# remove --force, rm -rf, git branch -D), so this matrix is deliberately wide.
# `gh` is a PATH-shadowing stub keyed by branch name; nothing here touches the
# network.
# =============================================================================

write_gh_stub() {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$GH_STUB_DIR"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<EOF
#!/usr/bin/env bash
# Only "gh pr view <branch> --json state -q .state" is used by the function
# under test. Canned answer lives in a file keyed by branch name; a missing
# file means gh itself failed (auth/network), for the fail-closed test.
if [ "\$1 \$2" = "pr view" ]; then
    f="$GH_STUB_DIR/\$3"
    if [ -f "\$f" ]; then
        cat "\$f"
        exit 0
    fi
    echo "gh: some error" >&2
    exit 1
fi
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# add_worktree <branch> [days-old] — creates a worktree off PRIMARY on a new
# branch with one commit, optionally backdated for the stale-age tests. Shares
# PRIMARY's object database, so a later `git -C "$PRIMARY" merge --ff-only
# <branch>` can simulate that commit having already landed on main.
add_worktree() {
    local branch="$1" days_old="${2:-0}" wt date_env
    wt="$BATS_TEST_TMPDIR/wt-$branch"
    git -C "$PRIMARY" worktree add --quiet -b "$branch" "$wt" main
    git -C "$wt" config user.email "t@example.com"
    git -C "$wt" config user.name "t"
    if [ "$days_old" -gt 0 ]; then
        date_env=$(date -v-"${days_old}"d +%Y-%m-%dT%H:%M:%S)
        GIT_AUTHOR_DATE="$date_env" GIT_COMMITTER_DATE="$date_env" \
            git -C "$wt" commit --quiet --allow-empty -m "commit on $branch"
    else
        git -C "$wt" commit --quiet --allow-empty -m "commit on $branch"
    fi
    echo "$wt"
}

setup_cleanup() {
    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    write_gh_stub
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "cleanup: a dirty worktree is never removed, even merged and gone from origin" {
    setup_cleanup
    WT=$(add_worktree feat-dirty)
    git -C "$PRIMARY" merge --quiet --ff-only feat-dirty
    echo "uncommitted" >"$WT/dirty.txt"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
    git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: the primary checkout is never touched" {
    setup_cleanup
    before_head="$(git -C "$PRIMARY" rev-parse HEAD)"
    before_branch="$(git -C "$PRIMARY" branch --show-current)"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before_head" ]
    [ "$(git -C "$PRIMARY" branch --show-current)" = "$before_branch" ]
    [ -d "$PRIMARY" ]
}

@test "cleanup: a branch merged into main and gone from origin gets its worktree removed" {
    setup_cleanup
    WT=$(add_worktree feat-merged)
    echo "MERGED" >"$GH_STUB_DIR/feat-merged"
    # Deliberately NOT fast-forward-merged into PRIMARY's local main: a real
    # squash-merge (this repo's actual `gh pr merge --squash` workflow) lands
    # a brand-new commit on main, so the original branch's commits are never
    # literally an ancestor of main -- ahead_count/is-ancestor can't shortcut
    # this, and the function correctly falls through to gh's PR-state
    # confirmation for the merged case too, not just for the closed-without-
    # merging case test 9 already covers.

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
    ! git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: an unmerged branch with no PR is retained" {
    setup_cleanup
    WT=$(add_worktree feat-unmerged)
    # Deliberately NOT merged into primary's main, and no canned gh answer for
    # this branch -- the stub's "no file" path simulates "no PR found".

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: an unmerged branch whose PR was closed without merging is removed" {
    setup_cleanup
    WT=$(add_worktree feat-closed)
    echo "CLOSED" >"$GH_STUB_DIR/feat-closed"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: an unmerged branch whose PR is still open is retained" {
    setup_cleanup
    WT=$(add_worktree feat-open)
    echo "OPEN" >"$GH_STUB_DIR/feat-open"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a gh failure during the PR-state check fails closed (retains)" {
    setup_cleanup
    WT=$(add_worktree feat-gh-down)
    # No canned answer AND the stub's own "gh: some error" exit-1 path fires --
    # simulates gh being unreachable/unauthenticated, not just "no PR".

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a clean worktree untouched for over 4 days is removed by the stale pass" {
    setup_cleanup
    WT=$(add_worktree feat-stale 10)
    # Left unmerged and with no gh answer, so the merged/PR pass retains it --
    # only the age-based stale pass should remove it.

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: a clean worktree touched within 4 days is retained by the stale pass" {
    setup_cleanup
    WT=$(add_worktree feat-fresh 1)

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: the worktree the caller is currently sitting in is never removed, even if stale" {
    setup_cleanup
    WT=$(add_worktree feat-current 10)

    (cd "$WT" && _cleanup_worktrees_and_branches "$PRIMARY")

    [ -d "$WT" ]
}
