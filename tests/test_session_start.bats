#!/usr/bin/env bats

# Tests for session_start.sh.
# Mocks git via a temp PATH dir; uses real jq (symlinked).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SESSION_START="$SCRIPT_DIR/scripts/session_start.sh"

setup() {
    MOCK_BIN="$(mktemp -d)"
    FAKE_REPO="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # --- Default mock config via env vars ---
    # MOCK_GIT_TOPLEVEL: path returned by rev-parse --show-toplevel ("" to fail)
    export MOCK_GIT_TOPLEVEL="$FAKE_REPO"
    # MOCK_GIT_BRANCH: current branch name ("" for detached HEAD)
    export MOCK_GIT_BRANCH="main"
    # MOCK_GIT_HAS_REMOTE: "yes" if origin/<branch> exists, "no" otherwise
    export MOCK_GIT_HAS_REMOTE="yes"
    # MOCK_GIT_MERGE: "uptodate", "merged", or "fail"
    export MOCK_GIT_MERGE="uptodate"
    # MOCK_GIT_BRANCH_VV: output of git branch -vv (multiline)
    export MOCK_GIT_BRANCH_VV=""
    # MOCK_GIT_LS_REMOTE: "yes" if ls-remote finds the branch, "no" otherwise
    export MOCK_GIT_LS_REMOTE="yes"

    # --- Mock: git ---
    cat > "$MOCK_BIN/git" <<'MOCK_GIT'
#!/usr/bin/env bash

# git rev-parse --show-toplevel
if [[ "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then
    if [[ -n "$MOCK_GIT_TOPLEVEL" ]]; then
        echo "$MOCK_GIT_TOPLEVEL"
        exit 0
    fi
    echo "fatal: not a git repository" >&2
    exit 128
fi

# git rev-parse --verify origin/<branch>
if [[ "$1" == "rev-parse" && "$2" == "--verify" ]]; then
    if [[ "$MOCK_GIT_HAS_REMOTE" == "yes" ]]; then
        echo "abc123"
        exit 0
    fi
    exit 1
fi

# git branch --show-current
if [[ "$1" == "branch" && "$2" == "--show-current" ]]; then
    echo "$MOCK_GIT_BRANCH"
    exit 0
fi

# git branch -vv
if [[ "$1" == "branch" && "$2" == "-vv" ]]; then
    if [[ -n "$MOCK_GIT_BRANCH_VV" ]]; then
        printf '%s\n' "$MOCK_GIT_BRANCH_VV"
    fi
    exit 0
fi

# git branch -D <branch>
if [[ "$1" == "branch" && "$2" == "-D" ]]; then
    exit 0
fi

# git fetch -p
if [[ "$1" == "fetch" ]]; then
    exit 0
fi

# git merge --ff-only
if [[ "$1" == "merge" && "$2" == "--ff-only" ]]; then
    case "$MOCK_GIT_MERGE" in
        uptodate)
            echo "Already up to date."
            exit 0
            ;;
        merged)
            echo "Updating abc123..def456"
            exit 0
            ;;
        fail)
            echo "fatal: Not possible to fast-forward, aborting." >&2
            echo "fatal: Not possible to fast-forward, aborting."
            exit 1
            ;;
    esac
fi

# git ls-remote --heads origin <branch>
if [[ "$1" == "ls-remote" && "$2" == "--heads" ]]; then
    branch="$4"
    if [[ "$MOCK_GIT_LS_REMOTE" == "yes" ]]; then
        echo "abc123	refs/heads/$branch"
        exit 0
    fi
    exit 0  # empty output = branch not found
fi

# git -C <dir> branch --show-current (for clone dirs)
if [[ "$1" == "-C" && "$3" == "branch" && "$4" == "--show-current" ]]; then
    dir="$2"
    # Read branch from a .mock_branch file we place in the clone dir
    if [[ -f "$dir/.mock_branch" ]]; then
        cat "$dir/.mock_branch"
    fi
    exit 0
fi

echo "git mock: unhandled command: $*" >&2
exit 1
MOCK_GIT
    chmod +x "$MOCK_BIN/git"

    # --- jq: use real jq (symlinked) ---
    REAL_JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
    if [[ ! -x "$REAL_JQ" ]]; then
        for p in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
            if [[ -x "$p" ]]; then
                REAL_JQ="$p"
                break
            fi
        done
    fi
    ln -sf "$REAL_JQ" "$MOCK_BIN/jq"
}

teardown() {
    rm -rf "$MOCK_BIN" "$FAKE_REPO"
}

# ---------- Test Cases ----------

@test "jq missing -> output contains 'jq is not installed', exits 0" {
    rm -f "$MOCK_BIN/jq"
    # Strip any directory containing jq from PATH so command -v jq fails.
    # Keep only MOCK_BIN (has mock git) and dirs needed for bash/coreutils.
    local old_path="$PATH"
    local new_path="$MOCK_BIN"
    local IFS=':'
    for dir in $old_path; do
        [[ "$dir" == "$MOCK_BIN" ]] && continue
        [[ -x "$dir/jq" ]] && continue
        new_path="$new_path:$dir"
    done
    export PATH="$new_path"

    run "$SESSION_START"

    export PATH="$old_path"
    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"jq is not installed"* ]]
}

@test "not a git repo -> output contains 'not a git repository', exits 0" {
    export MOCK_GIT_TOPLEVEL=""

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a git repository"* ]]
}

@test "environment OK -> output contains 'Environment: OK'" {
    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Environment: OK"* ]]
}

@test "git merge already up to date -> output contains 'Git: up to date'" {
    export MOCK_GIT_MERGE="uptodate"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Git: up to date"* ]]
}

@test "git merge succeeds (actual merge) -> output contains 'Git: merged'" {
    export MOCK_GIT_MERGE="merged"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Git: merged"* ]]
}

@test "git merge fails -> output contains 'Git: error:'" {
    export MOCK_GIT_MERGE="fail"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Git: error:"* ]]
}

@test "no remote tracking branch -> output contains 'Git: up to date'" {
    export MOCK_GIT_HAS_REMOTE="no"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Git: up to date"* ]]
}

@test "detached HEAD -> output contains 'Git: no current branch'" {
    export MOCK_GIT_BRANCH=""

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Git: no current branch"* ]]
}

@test "output is valid JSON" {
    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null 2>&1
}

@test "always exits 0 across different scenarios" {
    # Scenario: merge fail
    export MOCK_GIT_MERGE="fail"
    run "$SESSION_START"
    echo "merge fail STATUS: $status"
    [ "$status" -eq 0 ]

    # Scenario: not a git repo
    export MOCK_GIT_TOPLEVEL=""
    run "$SESSION_START"
    echo "not git repo STATUS: $status"
    [ "$status" -eq 0 ]

    # Scenario: detached HEAD
    export MOCK_GIT_TOPLEVEL="$FAKE_REPO"
    export MOCK_GIT_BRANCH=""
    run "$SESSION_START"
    echo "detached HEAD STATUS: $status"
    [ "$status" -eq 0 ]
}

@test "clone cleanup: removes clone dir when remote branch is gone" {
    # Set up a clone dir with a feature branch that no longer exists on remote
    mkdir -p "$FAKE_REPO/_clones/my-feature/.git"
    echo "my-feature" > "$FAKE_REPO/_clones/my-feature/.mock_branch"
    export MOCK_GIT_LS_REMOTE="no"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed: my-feature"* ]]
    # The clone dir should have been deleted
    [ ! -d "$FAKE_REPO/_clones/my-feature" ]
}

@test "clone cleanup: keeps clone dir on main branch" {
    mkdir -p "$FAKE_REPO/_clones/main-clone/.git"
    echo "main" > "$FAKE_REPO/_clones/main-clone/.mock_branch"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Existing: main-clone"* ]]
    [ -d "$FAKE_REPO/_clones/main-clone" ]
}

@test "clone cleanup: keeps clone dir when remote branch exists" {
    mkdir -p "$FAKE_REPO/_clones/active-feature/.git"
    echo "active-feature" > "$FAKE_REPO/_clones/active-feature/.mock_branch"
    export MOCK_GIT_LS_REMOTE="yes"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Existing: active-feature"* ]]
    [ -d "$FAKE_REPO/_clones/active-feature" ]
}

@test "cleans up local branches with gone tracking" {
    export MOCK_GIT_BRANCH_VV="* main                abc1234 [origin/main] some commit
  feature-old        def5678 [origin/feature-old: gone] old feature
  feature-active     ghi9012 [origin/feature-active] active feature"

    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed branch: feature-old"* ]]
}

@test "output JSON has systemMessage field" {
    run "$SESSION_START"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    msg=$(echo "$output" | jq -r '.systemMessage')
    [ "$msg" != "null" ]
    [ -n "$msg" ]
}
