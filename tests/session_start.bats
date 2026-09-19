#!/usr/bin/env bats
#
# Integration test for scripts/session_start.sh end to end: confirms the
# refactor that hoisted the _git_sync.sh source above the worktree-vs-
# primary-checkout branch (so cleanup runs for both) didn't change observable
# behavior, and that the script stays silent and always exits 0 per its own
# contract. The library functions themselves (sync, cleanup) are covered in
# depth by tests/_git_sync.bats; this only checks the entrypoint's wiring.

HOOK="${BATS_TEST_DIRNAME}/../scripts/session_start.sh"

setup() {
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    git init --quiet --bare -b main "$ORIGIN"

    PRIMARY="$BATS_TEST_TMPDIR/primary"
    git clone --quiet "$ORIGIN" "$PRIMARY"
    git -C "$PRIMARY" config user.email "t@example.com"
    git -C "$PRIMARY" config user.name "t"
    git -C "$PRIMARY" commit --quiet --allow-empty -m "initial"
    git -C "$PRIMARY" push --quiet origin main

    # Point the RTK cooldown marker somewhere throwaway, pre-populated as
    # "just ran" -- this must NEVER depend on the real machine's marker file
    # or system clock, or this suite could trigger a real `brew`/`rtk`
    # network call and modify real global hook files.
    export RTK_UPDATE_MARKER="$BATS_TEST_TMPDIR/rtk_marker"
    date +%s >"$RTK_UPDATE_MARKER"
}

@test "running from the primary checkout exits 0 and prints nothing" {
    run bash -c "cd '$PRIMARY' && bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "running from the primary checkout still leaves it on main, synced to origin" {
    OTHER="$BATS_TEST_TMPDIR/other"
    git clone --quiet "$ORIGIN" "$OTHER"
    git -C "$OTHER" config user.email "t@example.com"
    git -C "$OTHER" config user.name "t"
    git -C "$OTHER" commit --quiet --allow-empty -m "landed elsewhere"
    git -C "$OTHER" push --quiet origin main

    run bash -c "cd '$PRIMARY' && bash '$HOOK'"
    [ "$status" -eq 0 ]

    [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$(git -C "$OTHER" rev-parse HEAD)" ]
    [ "$(git -C "$PRIMARY" branch --show-current)" = "main" ]
}

@test "running from the primary checkout still runs cleanup: a merged, gone-from-origin worktree branch is removed" {
    WT="$BATS_TEST_TMPDIR/wt-feat"
    git -C "$PRIMARY" worktree add --quiet -b feat-merged "$WT" main
    git -C "$PRIMARY" config user.email "t@example.com"
    git -C "$PRIMARY" config user.name "t"

    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    mkdir -p "$GH_STUB_DIR" "$BATS_TEST_TMPDIR/bin"
    echo "MERGED" >"$GH_STUB_DIR/feat-merged"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
    f="$GH_STUB_DIR/\$3"
    [ -f "\$f" ] && cat "\$f" && exit 0
    exit 1
fi
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"

    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "cd '$PRIMARY' && bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -d "$WT" ]
}

@test "running from a linked worktree exits 0 and prints nothing" {
    WT="$BATS_TEST_TMPDIR/wt-plain"
    git -C "$PRIMARY" worktree add --quiet -b plain-feature "$WT" main

    run bash -c "cd '$WT' && bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "running from a directory that is not a git repo exits 0 and prints nothing" {
    NOTAREPO="$BATS_TEST_TMPDIR/notarepo"
    mkdir -p "$NOTAREPO"
    run bash -c "cd '$NOTAREPO' && bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
