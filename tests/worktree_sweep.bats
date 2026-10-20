#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/worktree_sweep.sh"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export WORKTREE_SWEEP_DELAY=0
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    git init --quiet --bare -b main "$ORIGIN"
    PRIMARY="$BATS_TEST_TMPDIR/primary"
    git clone --quiet "$ORIGIN" "$PRIMARY" 2>/dev/null
    git -C "$PRIMARY" config user.email "t@example.com"
    git -C "$PRIMARY" config user.name "t"
    git -C "$PRIMARY" commit --quiet --allow-empty -m "initial"
    git -C "$PRIMARY" push --quiet origin main
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\necho MERGED\n' >"$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "the sweep returns immediately and later removes a merged worktree whose lock pid is dead" {
    mkdir -p "$PRIMARY/.claude/worktrees"
    WT="$PRIMARY/.claude/worktrees/wt-sweep"
    git -C "$PRIMARY" worktree add --quiet -b feat-sweep "$WT" main
    git -C "$WT" config user.email "t@example.com"
    git -C "$WT" config user.name "t"
    git -C "$WT" commit --quiet --allow-empty -m "work"
    sleep 0 &
    dead=$!
    wait "$dead"
    git -C "$PRIMARY" worktree lock --reason "claude agent agent-x (pid $dead)" "$WT"

    cd "$PRIMARY"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 50); do
        [ -d "$WT" ] || break
        sleep 0.2
    done
    [ ! -d "$WT" ]
}

@test "outside a git repo the sweep exits 0 and does nothing" {
    cd "$BATS_TEST_TMPDIR"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "settings.json runs the sweep at SessionEnd and SubagentStop" {
    for event in SessionEnd SubagentStop; do
        run jq -e --arg e "$event" 'any(.hooks[$e][].hooks[]; .command | endswith("/scripts/worktree_sweep.sh"))' "$SETTINGS"
        [ "$status" -eq 0 ]
    done
}
