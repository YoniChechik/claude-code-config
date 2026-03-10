#!/usr/bin/env bats

# Tests for git_branch_state.sh.
# Mocks git via a temp PATH dir with env-var-controlled behavior; symlinks real jq.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/git_branch_state.sh"

setup() {
    # Create temp dir for mock binaries and prepend to PATH
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # --- Default mock config via env vars ---
    export MOCK_IN_WORK_TREE="true"   # git rev-parse --is-inside-work-tree succeeds
    export MOCK_HAS_ORIGIN="true"     # git remote includes "origin"
    export MOCK_BRANCH="feat"         # git symbolic-ref --short HEAD returns this (empty = fail)
    export MOCK_HAS_REMOTE_BRANCH="true"  # origin/$branch exists
    export MOCK_HAS_ORIGIN_MAIN="true"    # origin/main exists
    export MOCK_LOCAL_ONLY="0"        # commits ahead of origin/$branch
    export MOCK_REMOTE_ONLY="0"       # commits behind origin/$branch
    export MOCK_BEHIND_MAIN="0"       # commits behind origin/main

    # --- Mock: git ---
    cat > "$MOCK_BIN/git" <<'MOCK_GIT'
#!/usr/bin/env bash

# rev-parse --is-inside-work-tree
if [[ "$1" == "rev-parse" && "$2" == "--is-inside-work-tree" ]]; then
    if [[ "$MOCK_IN_WORK_TREE" == "true" ]]; then
        echo "true"
        exit 0
    else
        exit 128
    fi
fi

# remote
if [[ "$1" == "remote" && $# -eq 1 ]]; then
    if [[ "$MOCK_HAS_ORIGIN" == "true" ]]; then
        echo "origin"
    fi
    exit 0
fi

# symbolic-ref --short HEAD
if [[ "$1" == "symbolic-ref" && "$2" == "--short" && "$3" == "HEAD" ]]; then
    if [[ -n "$MOCK_BRANCH" ]]; then
        echo "$MOCK_BRANCH"
        exit 0
    else
        exit 128
    fi
fi

# rev-parse --verify origin/<branch> or origin/main
if [[ "$1" == "rev-parse" && "$2" == "--verify" ]]; then
    ref="$3"
    if [[ "$ref" == "origin/main" ]]; then
        if [[ "$MOCK_HAS_ORIGIN_MAIN" == "true" ]]; then
            echo "abc123"
            exit 0
        else
            exit 128
        fi
    elif [[ "$ref" == "origin/$MOCK_BRANCH" ]]; then
        if [[ "$MOCK_HAS_REMOTE_BRANCH" == "true" ]]; then
            echo "abc123"
            exit 0
        else
            exit 128
        fi
    fi
    exit 128
fi

# rev-list with --count
if [[ "$1" == "rev-list" ]]; then
    range="$2"
    if [[ "$range" == "origin/${MOCK_BRANCH}..HEAD" ]]; then
        echo "$MOCK_LOCAL_ONLY"
        exit 0
    elif [[ "$range" == "HEAD..origin/${MOCK_BRANCH}" ]]; then
        echo "$MOCK_REMOTE_ONLY"
        exit 0
    elif [[ "$range" == "HEAD..origin/main" ]]; then
        echo "$MOCK_BEHIND_MAIN"
        exit 0
    fi
fi

echo "git mock: unhandled command: $*" >&2
exit 1
MOCK_GIT
    chmod +x "$MOCK_BIN/git"

    # --- jq: use real jq (not mocked) ---
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
    rm -rf "$MOCK_BIN"
}

# ---------- Test Cases ----------

@test "Normal branch, no divergence, 0 behind main" {
    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.branch')" = "feat" ]
    [ "$(echo "$output" | jq '.diverged')" = "false" ]
    [ "$(echo "$output" | jq '.behind_main')" = "0" ]
}

@test "Branch diverged (local_only>0 and remote_only>0)" {
    export MOCK_LOCAL_ONLY="3"
    export MOCK_REMOTE_ONLY="2"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.diverged')" = "true" ]
}

@test "Branch behind main by N" {
    export MOCK_BEHIND_MAIN="5"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.behind_main')" = "5" ]
}

@test "Not inside git work tree -> exit 0, empty output" {
    export MOCK_IN_WORK_TREE="false"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "No origin remote -> exit 0, empty output" {
    export MOCK_HAS_ORIGIN="false"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Detached HEAD (symbolic-ref fails) -> exit 0, empty output" {
    export MOCK_BRANCH=""

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "No remote tracking branch -> diverged is false" {
    export MOCK_HAS_REMOTE_BRANCH="false"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.diverged')" = "false" ]
}

@test "No origin/main -> behind_main defaults to 0" {
    export MOCK_HAS_ORIGIN_MAIN="false"

    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.behind_main')" = "0" ]
}

@test "Output is valid JSON" {
    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null 2>&1
}
