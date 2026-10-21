#!/usr/bin/env bats

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

write_gh_stub() {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$GH_STUB_DIR"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<EOF
#!/usr/bin/env bash
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

age_admin() {
    local admin
    admin=$(git -C "$1" rev-parse --absolute-git-dir)
    find "$admin" -exec touch -h -t 202001010000 {} +
}

age_worktree() {
    age_tree "$1"
    age_admin "$1"
}

add_worktree() {
    local branch="$1" days_old="${2:-1}" fresh="${3:-}" wt date_env
    mkdir -p "$PRIMARY/.claude/worktrees"
    wt="$PRIMARY/.claude/worktrees/wt-$branch"
    git -C "$PRIMARY" worktree add --quiet -b "$branch" "$wt" main
    git -C "$wt" config user.email "t@example.com"
    git -C "$wt" config user.name "t"
    if [ "$fresh" = "fresh" ]; then
        git -C "$wt" commit --quiet --allow-empty -m "commit on $branch"
    else
        date_env=$(date -v-"${days_old}"d +%Y-%m-%dT%H:%M:%S)
        GIT_AUTHOR_DATE="$date_env" GIT_COMMITTER_DATE="$date_env" \
            git -C "$wt" commit --quiet --allow-empty -m "commit on $branch"
        age_worktree "$wt"
    fi
    echo "$wt"
}

pr_answer() {
    local head="${3:-$(git -C "$PRIMARY" rev-parse "refs/heads/$1")}"
    echo "$2 $head" >"$GH_STUB_DIR/$1"
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
    pr_answer feat-merged MERGED

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
    ! git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: an unmerged branch with no PR is retained" {
    setup_cleanup
    WT=$(add_worktree feat-unmerged)

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: an unmerged branch whose PR was closed without merging is removed" {
    setup_cleanup
    WT=$(add_worktree feat-closed)
    pr_answer feat-closed CLOSED

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: an unmerged branch whose PR is still open is retained" {
    setup_cleanup
    WT=$(add_worktree feat-open)
    pr_answer feat-open OPEN

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a gh failure during the PR-state check fails closed (retains)" {
    setup_cleanup
    WT=$(add_worktree feat-gh-down)

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a clean worktree untouched for over 4 days is removed by the stale pass" {
    setup_cleanup
    WT=$(add_worktree feat-stale 10)
    git -C "$WT" push --quiet origin feat-stale
    age_worktree "$WT"

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
    pr_answer feat-locked-dead MERGED
    lock_worktree "$WT" "$(dead_pid)"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
    ! git -C "$PRIMARY" worktree list | grep -qF "$WT"
}

@test "cleanup: a locked worktree whose lock pid is alive is kept" {
    setup_cleanup
    WT=$(add_worktree feat-locked-live)
    pr_answer feat-locked-live MERGED
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
    pr_answer feat-locked-busy MERGED
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
    pr_answer feat-fail MERGED
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
    pr_answer feat-on-origin MERGED

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: commits not on origin keep the worktree even when the PR is merged" {
    setup_cleanup
    WT=$(add_worktree feat-unpushed)
    git -C "$WT" push --quiet origin feat-unpushed
    pr_answer feat-unpushed MERGED
    git -C "$WT" commit --quiet --allow-empty -m "local only"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: an open PR keeps the worktree when the branch exists on origin" {
    setup_cleanup
    WT=$(add_worktree feat-open-on-origin)
    git -C "$WT" push --quiet origin feat-open-on-origin
    pr_answer feat-open-on-origin OPEN

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a detached worktree with nothing unique versus origin/main is removed" {
    setup_cleanup
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-detached-clean"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main
    age_worktree "$WT"

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
    age_worktree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a detached worktree with an unpushed commit older than 4 days is kept" {
    setup_cleanup
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-detached-old"
    git -C "$PRIMARY" worktree add --quiet --detach "$WT" main
    git -C "$WT" config user.email "t@example.com"
    git -C "$WT" config user.name "t"
    old=$(date -v-10d +%Y-%m-%dT%H:%M:%S)
    GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -C "$WT" commit --quiet --allow-empty -m "old unique"
    age_worktree "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
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
    age_worktree "$WT"

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
    pr_answer feat-dirty-locked MERGED
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
    pr_answer feat-lsof-fail MERGED
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
    pr_answer feat-elsewhere MERGED
    mkdir -p "$PRIMARY/.claude/worktrees"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$OUT" ]
    git -C "$PRIMARY" worktree list | grep -qF "elsewhere-wt"
}

make_old_pr_head() {
    git -C "$PRIMARY" checkout --quiet -b old-pr-branch
    git -C "$PRIMARY" commit --quiet --allow-empty -m "old PR work"
    OLD_HEAD=$(git -C "$PRIMARY" rev-parse HEAD)
    git -C "$PRIMARY" checkout --quiet main
    git -C "$PRIMARY" commit --quiet --allow-empty -m "squash of the old PR"
    git -C "$PRIMARY" push --quiet origin main
}

@test "cleanup: a reused branch name with commits beyond its old merged PR head is kept" {
    setup_cleanup
    make_old_pr_head
    WT=$(add_worktree feat-reused)
    pr_answer feat-reused MERGED "$OLD_HEAD"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
    grep -q "keep: branch has commits beyond the head of its MERGED PR" "$CLAUDE_HOOK_LOG_DIR/hooks.log"
}

@test "cleanup: a reused branch name cut from a newer main with no commits of its own is kept" {
    setup_cleanup
    make_old_pr_head
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-reused-empty"
    git -C "$PRIMARY" worktree add --quiet -b feat-reused-empty "$WT" main
    age_worktree "$WT"
    pr_answer feat-reused-empty MERGED "$OLD_HEAD"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a reused branch name whose old PR was closed is kept" {
    setup_cleanup
    make_old_pr_head
    WT=$(add_worktree feat-reused-closed)
    pr_answer feat-reused-closed CLOSED "$OLD_HEAD"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a merged PR whose head commit is unknown locally keeps the worktree" {
    setup_cleanup
    WT=$(add_worktree feat-unknown-head)
    pr_answer feat-unknown-head MERGED 0123456789abcdef0123456789abcdef01234567

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a branch whose tip is behind its merged PR head is removed" {
    setup_cleanup
    WT=$(add_worktree feat-behind)
    tip=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" commit --quiet --allow-empty -m "pushed later from elsewhere"
    head=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" reset --quiet --hard "$tip"
    age_worktree "$WT"
    pr_answer feat-behind MERGED "$head"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ ! -d "$WT" ]
}

@test "cleanup: a worktree created moments ago is kept even when its PR is merged" {
    setup_cleanup
    WT=$(add_worktree feat-just-made 1 fresh)
    pr_answer feat-just-made MERGED

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a worktree with a commit inside the idle window is kept even when its PR is merged" {
    setup_cleanup
    WT=$(add_worktree feat-recent-commit)
    git -C "$WT" commit --quiet --allow-empty -m "just now"
    age_tree "$WT"
    pr_answer feat-recent-commit MERGED

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: a worktree whose files changed inside the idle window is kept even when its PR is merged" {
    setup_cleanup
    WT=$(add_worktree feat-recent-file)
    pr_answer feat-recent-file MERGED
    mkdir -p "$WT/sub"
    touch -t 202001010000 "$WT"

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}

@test "cleanup: the idle window is configurable" {
    setup_cleanup
    WT=$(add_worktree feat-idle-window 1 fresh)
    pr_answer feat-idle-window MERGED
    date_env=$(date -v-3H +%Y%m%d%H%M)
    find "$WT" "$(git -C "$WT" rev-parse --absolute-git-dir)" -exec touch -h -t "$date_env" {} +
    old=$(date -v-3H +%Y-%m-%dT%H:%M:%S)
    git -C "$WT" commit --quiet --amend --allow-empty --no-edit --date="$old"
    GIT_COMMITTER_DATE="$old" git -C "$WT" commit --quiet --amend --allow-empty --no-edit
    find "$WT" "$(git -C "$WT" rev-parse --absolute-git-dir)" -exec touch -h -t "$date_env" {} +
    pr_answer feat-idle-window MERGED

    _cleanup_worktrees_and_branches "$PRIMARY"
    [ -d "$WT" ]

    WORKTREE_SWEEP_IDLE_HOURS=2 _cleanup_worktrees_and_branches "$PRIMARY"
    [ ! -d "$WT" ]
}

@test "cleanup: a stale worktree with unpushed commits is kept" {
    setup_cleanup
    WT=$(add_worktree feat-stale-unpushed 10)

    _cleanup_worktrees_and_branches "$PRIMARY"

    [ -d "$WT" ]
}
