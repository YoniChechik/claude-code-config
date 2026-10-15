#!/usr/bin/env bats

CREATE="${BATS_TEST_DIRNAME}/../skills/create-worktree/create_worktree.sh"
SETUP="${BATS_TEST_DIRNAME}/../skills/worktree-lifecycle/setup_worktree.sh"
DESTROY="${BATS_TEST_DIRNAME}/../skills/worktree-lifecycle/destroy_worktree.sh"


setup() {
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
    git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/repo" 2>/dev/null
    git -C "$BATS_TEST_TMPDIR/repo" checkout -q -b main
    git -C "$BATS_TEST_TMPDIR/repo" commit -q --allow-empty -m init
    git -C "$BATS_TEST_TMPDIR/repo" push -q -u origin main
}

flat() { printf '%s' "${1##*/}"; }

create() { (cd "$BATS_TEST_TMPDIR/repo" && bash "$CREATE" "$1" 2>/dev/null | tail -n 1); }

@test "name of 58 characters or fewer is used unchanged" {
    local name="dev-1143-short-name"
    run create "$name"
    [ "$status" -eq 0 ]
    [ "$output" = ".claude/worktrees/$name" ]
    local max
    max=$(printf 'a%.0s' $(seq 1 58))
    run create "$max"
    [ "$output" = ".claude/worktrees/$max" ]
}

@test "63-character Linear-style name is capped to 58 or fewer" {
    local name="dev-1143-fix-the-worktree-socket-path-limit-for-devtrees-boot-x"
    [ "${#name}" -eq 63 ]
    run create "$name"
    [ "$status" -eq 0 ]
    local dir
    dir=$(flat "$output")
    [ "${#dir}" -le 58 ]
    [ "${dir:0:20}" = "${name:0:20}" ]
    [[ "$dir" != *- ]]
    [ -d "$BATS_TEST_TMPDIR/repo/$output" ]
    git -C "$BATS_TEST_TMPDIR/repo" show-ref --verify --quiet "refs/heads/$name"
}

@test "capping is deterministic and distinct names stay distinct" {
    local a="dev-1143-fix-the-worktree-socket-path-limit-for-devtrees-boot-x"
    local b="dev-1143-fix-the-worktree-socket-path-limit-for-devtrees-bolt-x"
    run create "$a"
    local first="$output"
    run create "$b"
    [ "$output" != "$first" ]
    (cd "$BATS_TEST_TMPDIR/repo" && bash "$DESTROY" "$a" --force >/dev/null 2>&1)
    run create "$a"
    [ "$output" = "$first" ]
}

@test "destroy finds a capped worktree by branch name, directory name and path" {
    local name="dev-1143-fix-the-worktree-socket-path-limit-for-devtrees-boot-x"
    local rel
    rel=$(create "$name")
    run bash -c "cd '$BATS_TEST_TMPDIR/repo' && bash '$DESTROY' '$name' --force"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/repo/$rel" ]
    rel=$(create "$name")
    run bash -c "cd '$BATS_TEST_TMPDIR/repo' && bash '$DESTROY' '$(flat "$rel")' --force"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/repo/$rel" ]
    rel=$(create "$name")
    run bash -c "cd '$BATS_TEST_TMPDIR/repo' && bash '$DESTROY' '$BATS_TEST_TMPDIR/repo/$rel' --force"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/repo/$rel" ]
}

@test "setup_worktree.sh applies the same cap" {
    local name="dev-1143-fix-the-worktree-socket-path-limit-for-devtrees-boot-x"
    local out
    out=$(cd "$BATS_TEST_TMPDIR/repo" && bash "$SETUP" "$name" 2>/dev/null | tail -n 1)
    local dir
    dir=$(flat "$out")
    [ "${#dir}" -le 58 ]
    [ "${dir:0:20}" = "${name:0:20}" ]
    [ -d "$BATS_TEST_TMPDIR/repo/$out" ]
}
