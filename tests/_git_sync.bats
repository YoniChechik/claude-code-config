#!/usr/bin/env bats
#
# Tests for scripts/_git_sync.sh's _sync_primary_checkout_to_origin_main,
# shared by session_start.sh and post_tool_use__sync_main_after_merge.sh.
#
# Uses REAL git repos in BATS_TEST_TMPDIR rather than a PATH-shadowing stub:
# the function's whole job is real filesystem git state (branch, HEAD,
# working tree), which a stub would only re-describe, not verify.


setup() {
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    source "${BATS_TEST_DIRNAME}/../scripts/_git_sync.sh"

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

age_tree() {
    find "$1" -exec touch -h -t 202001010000 {} +
}

# add_worktree <branch> [days-old] — creates a worktree off PRIMARY on a new
# branch with one commit, optionally backdated for the stale-age tests. Shares
# PRIMARY's object database, so a later `git -C "$PRIMARY" merge --ff-only
# <branch>` can simulate that commit having already landed on main.
add_worktree() {
    local branch="$1" days_old="${2:-0}" wt date_env
    mkdir -p "$PRIMARY/.claude/worktrees"
    wt="$PRIMARY/.claude/worktrees/wt-$branch"
    git -C "$PRIMARY" worktree add --quiet -b "$branch" "$wt" main
    git -C "$wt" config user.email "t@example.com"
    git -C "$wt" config user.name "t"
    if [ "$days_old" -gt 0 ]; then
        date_env=$(date -v-"${days_old}"d +%Y-%m-%dT%H:%M:%S)
        GIT_AUTHOR_DATE="$date_env" GIT_COMMITTER_DATE="$date_env" \
            git -C "$wt" commit --quiet --allow-empty -m "commit on $branch"
        age_tree "$wt"
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

dead_pid() {
    local p
    sleep 0 &
    p=$!
    wait "$p"
    echo "$p"
}

lock_worktree() {
    git -C "$PRIMARY" worktree lock --reason "claude agent agent-test (pid $2)" "$1"
}

@test "cleanup: a locked worktree whose lock pid is dead is unlocked and removed" {
    setup_cleanup
    WT=$(add_worktree feat-locked-dead)
    echo "MERGED" >"$GH_STUB_DIR/feat-locked-dead"
    lock_worktree "$WT" "$(dead_pid)"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
    ! git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: a locked worktree whose lock pid is alive is kept" {
    setup_cleanup
    WT=$(add_worktree feat-locked-live)
    echo "MERGED" >"$GH_STUB_DIR/feat-locked-live"
    sleep 300 >/dev/null 2>&1 3>&- &
    live=$!
    lock_worktree "$WT" "$live"

    _cleanup_worktrees_and_branches "$PRIMARY"
    kill "$live"

    [ -d "$WT" ]
    git -C "$PRIMARY" worktree list --porcelain | grep -q "^locked"
    grep -q "held by a live process" "$CLAUDE_HOOK_LOG_DIR/hooks.log"
}

@test "cleanup: a locked worktree with a dead pid but a process inside it is kept" {
    setup_cleanup
    WT=$(add_worktree feat-locked-busy)
    echo "MERGED" >"$GH_STUB_DIR/feat-locked-busy"
    lock_worktree "$WT" "$(dead_pid)"
    (cd "$WT" && exec sleep 300) >/dev/null 2>&1 3>&- &
    busy=$!

    _cleanup_worktrees_and_branches "$PRIMARY"
    kill "$busy"

    [ -d "$WT" ]
}

@test "cleanup: a failed removal is logged instead of swallowed" {
    setup_cleanup
    WT=$(add_worktree feat-fail)
    echo "MERGED" >"$GH_STUB_DIR/feat-fail"
    real_git=$(command -v git)
    cat >"$BATS_TEST_TMPDIR/bin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "remove" ]; then echo "fatal: simulated failure" >&2; exit 128; fi
done
exec "$real_git" "\$@"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/git"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
    grep -q "remove failed: fatal: simulated failure" "$CLAUDE_HOOK_LOG_DIR/hooks.log"
}

@test "cleanup: a merged PR removes the worktree even when the branch still exists on origin" {
    setup_cleanup
    WT=$(add_worktree feat-on-origin)
    git -C "$WT" push --quiet origin feat-on-origin
    echo "MERGED" >"$GH_STUB_DIR/feat-on-origin"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: commits not on origin keep the worktree even when the PR is merged" {
    setup_cleanup
    WT=$(add_worktree feat-unpushed)
    git -C "$WT" push --quiet origin feat-unpushed
    git -C "$WT" commit --quiet --allow-empty -m "local only"
    echo "MERGED" >"$GH_STUB_DIR/feat-unpushed"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: an open PR keeps the worktree when the branch exists on origin" {
    setup_cleanup
    WT=$(add_worktree feat-open-on-origin)
    git -C "$WT" push --quiet origin feat-open-on-origin
    echo "OPEN" >"$GH_STUB_DIR/feat-open-on-origin"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a detached worktree with nothing unique versus origin/main is removed" {
    setup_cleanup
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-detached-clean"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main
    age_tree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: a detached worktree with a unique recent commit is kept" {
    setup_cleanup
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-detached-unique"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main
    git -C "$WT" config user.email "t@example.com"
    git -C "$WT" config user.name "t"
    git -C "$WT" commit --quiet --allow-empty -m "unique"
    age_tree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a detached worktree with a unique commit older than 4 days is removed" {
    setup_cleanup
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-detached-old"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main
    git -C "$WT" config user.email "t@example.com"
    git -C "$WT" config user.name "t"
    old=$(date -v-10d +%Y-%m-%dT%H:%M:%S)
    GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$WT" commit --quiet --allow-empty -m "old unique"
    age_tree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: an unregistered directory under .claude/worktrees with no process inside is removed" {
    setup_cleanup
    ORPHAN="$PRIMARY/.claude/worktrees/orphan"
    mkdir -p "$ORPHAN"
    echo x >"$ORPHAN/file"
    age_tree "$ORPHAN"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$ORPHAN" ]
}

@test "cleanup: an unregistered directory with a process inside is kept" {
    setup_cleanup
    ORPHAN="$PRIMARY/.claude/worktrees/orphan-busy"
    mkdir -p "$ORPHAN"
    age_tree "$ORPHAN"
    (cd "$ORPHAN" && exec sleep 300) >/dev/null 2>&1 3>&- &
    busy=$!

    _cleanup_worktrees_and_branches "$PRIMARY"
    kill "$busy"

    [ -d "$ORPHAN" ]
}

@test "cleanup: a freshly created unregistered directory is kept" {
    setup_cleanup
    ORPHAN="$PRIMARY/.claude/worktrees/orphan-fresh"
    mkdir -p "$ORPHAN"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$ORPHAN" ]
}

@test "cleanup: a registered worktree directory is not treated as an orphan" {
    setup_cleanup
    WT="$PRIMARY/.claude/worktrees/registered"
    git -C "$PRIMARY" worktree add --quiet -b feat-registered "$WT" main
    git -C "$WT" config user.email "t@example.com"
    git -C "$WT" config user.name "t"
    git -C "$WT" commit --quiet --allow-empty -m "work"
    age_tree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a locked ghost entry whose directory is missing is unlocked and pruned" {
    setup_cleanup
    WT=$(add_worktree feat-ghost)
    lock_worktree "$WT" "$(dead_pid)"
    rm -rf "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    ! git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: a symlinked orphan is skipped and its target is untouched" {
    setup_cleanup
    OUTSIDE="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$OUTSIDE" "$PRIMARY/.claude/worktrees"
    echo precious >"$OUTSIDE/file"
    age_tree "$OUTSIDE"
    ln -s "$OUTSIDE" "$PRIMARY/.claude/worktrees/link"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -f "$OUTSIDE/file" ]
    [ -L "$PRIMARY/.claude/worktrees/link" ]
}

@test "cleanup: an orphan with an unregistered git pointer is kept" {
    setup_cleanup
    ORPHAN="$PRIMARY/.claude/worktrees/orphan-git"
    mkdir -p "$ORPHAN"
    echo "gitdir: /nonexistent" >"$ORPHAN/.git"
    echo work >"$ORPHAN/edit.txt"
    age_tree "$ORPHAN"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -f "$ORPHAN/edit.txt" ]
}

@test "cleanup: an orphan whose top dir is old but holds a recent file is kept" {
    setup_cleanup
    ORPHAN="$PRIMARY/.claude/worktrees/orphan-recent"
    mkdir -p "$ORPHAN/sub"
    age_tree "$ORPHAN"
    echo fresh >"$ORPHAN/sub/new.txt"
    touch -t 202001010000 "$ORPHAN" "$ORPHAN/sub"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -f "$ORPHAN/sub/new.txt" ]
}

@test "cleanup: a fresh detached worktree with nothing unique is kept" {
    setup_cleanup
    WT="$PRIMARY/.claude/worktrees/wt-detached-fresh"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a dirty locked worktree with a dead pid is kept" {
    setup_cleanup
    WT=$(add_worktree feat-dirty-locked)
    echo "MERGED" >"$GH_STUB_DIR/feat-dirty-locked"
    lock_worktree "$WT" "$(dead_pid)"
    echo "uncommitted" >"$WT/dirty.txt"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -f "$WT/dirty.txt" ]
}

@test "cleanup: a fresh branch cut from an old main is kept by the age rule" {
    setup_cleanup
    old=$(date -v-10d +%Y-%m-%dT%H:%M:%S)
    GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$PRIMARY" commit --quiet --allow-empty -m "old main"
    git -C "$PRIMARY" push --quiet origin main
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-fresh-from-old"
    git -C "$PRIMARY" worktree add --quiet -b feat-fresh-old "$WT" main

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: when lsof fails every worktree is treated as in use and kept" {
    setup_cleanup
    WT=$(add_worktree feat-lsof-fail)
    echo "MERGED" >"$GH_STUB_DIR/feat-lsof-fail"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/lsof"
    chmod +x "$BATS_TEST_TMPDIR/bin/lsof"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
    grep -q "process snapshot failed" "$CLAUDE_HOOK_LOG_DIR/hooks.log"
}

@test "cleanup: a worktree outside the .claude/worktrees directory is never removed" {
    setup_cleanup
    OUT="$BATS_TEST_TMPDIR/elsewhere-wt"
    git -C "$PRIMARY" worktree add --quiet -b feat-elsewhere "$OUT" main
    echo "MERGED" >"$GH_STUB_DIR/feat-elsewhere"
    mkdir -p "$PRIMARY/.claude/worktrees"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$OUT" ]
    git -C "$PRIMARY" worktree list | grep -qF "elsewhere-wt"
}
