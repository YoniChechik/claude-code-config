#!/usr/bin/env bats

# Tests for merge conflict detection in ci_watch.sh.
# Mocks all external commands (gh, git, jq, sleep) via a temp PATH dir.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CI_WATCH="$SCRIPT_DIR/scripts/ci_watch.sh"

setup() {
    # Create temp dir for mock binaries and prepend to PATH
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # --- Default mock config via env vars ---
    # MOCK_MERGEABLE controls gh pr view response: MERGEABLE, CONFLICTING, or NO_PR
    export MOCK_MERGEABLE="MERGEABLE"
    # MOCK_CI_SCENARIO controls what gh run list / gh run view return:
    #   "pass"    - all workflows completed successfully
    #   "fail"    - one workflow failed
    #   "none"    - no CI workflows (empty array)
    export MOCK_CI_SCENARIO="pass"

    # --- Mock: sleep (no-op) ---
    cat > "$MOCK_BIN/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$MOCK_BIN/sleep"

    # --- Mock: git ---
    cat > "$MOCK_BIN/git" <<'MOCK_GIT'
#!/usr/bin/env bash
# git rev-parse <branch> -> fixed SHA
if [[ "$1" == "rev-parse" ]]; then
    echo "abc123"
    exit 0
fi
# Fallback: pass through
command git "$@"
MOCK_GIT
    chmod +x "$MOCK_BIN/git"

    # --- Mock: gh ---
    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash

# --- gh pr view ---
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    mergeable="$MOCK_MERGEABLE"

    # Handle NO_PR: simulate gh pr view failing (no PR exists)
    if [[ "$mergeable" == "NO_PR" ]]; then
        echo "no pull requests found" >&2
        exit 1
    fi

    # If --jq is present, echo the value directly instead of JSON
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            echo "$mergeable"
            exit 0
        fi
    done

    echo "{\"mergeable\":\"$mergeable\"}"
    exit 0
fi

# --- gh run list ---
if [[ "$1" == "run" && "$2" == "list" ]]; then
    case "$MOCK_CI_SCENARIO" in
        pass)
            echo '[{"databaseId":100,"status":"completed","conclusion":"success","name":"CI","headSha":"abc123"}]'
            ;;
        fail)
            echo '[{"databaseId":200,"status":"completed","conclusion":"failure","name":"CI","headSha":"abc123"}]'
            ;;
        none)
            echo '[]'
            ;;
    esac
    exit 0
fi

# --- gh run view ---
if [[ "$1" == "run" && "$2" == "view" ]]; then
    # Return a failed job for the failure scenario
    echo '{"jobs":[{"name":"build","conclusion":"failure"}]}'
    exit 0
fi

echo "gh mock: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$MOCK_BIN/gh"

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

    # --- Patch the script: set small MAX_ITERATIONS and POLL_INTERVAL=0 ---
    PATCHED_SCRIPT="$MOCK_BIN/ci_watch_patched.sh"
    sed \
        -e 's/^POLL_INTERVAL=.*/POLL_INTERVAL=0/' \
        -e 's/^MAX_TIMEOUT=.*/MAX_TIMEOUT=0/' \
        -e 's|^MAX_ITERATIONS=.*|MAX_ITERATIONS=4|' \
        "$CI_WATCH" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    rm -rf "$MOCK_BIN"
}

# ---------- Test Cases ----------

@test "CI passes + no conflicts -> exit 0, output contains 'CI passed'" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
}

@test "CI passes + conflicts -> exit 1, output contains 'merge conflicts'" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "No CI workflows + no conflicts -> exit 0, output contains 'No CI workflows'" {
    export MOCK_CI_SCENARIO="none"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No CI workflows"* ]]
}

@test "No CI workflows + conflicts -> exit 1, output contains 'merge conflicts'" {
    export MOCK_CI_SCENARIO="none"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "CI fails + conflicts -> exit 1, output contains 'merge conflicts'" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "No PR exists (gh pr view fails) -> skip conflict check, CI passes" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="NO_PR"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
}
