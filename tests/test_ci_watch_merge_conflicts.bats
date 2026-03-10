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
    # MOCK_MERGEABLE controls gh pr view response: MERGEABLE, CONFLICTING, UNKNOWN, or NO_PR
    export MOCK_MERGEABLE="MERGEABLE"
    # MOCK_CI_SCENARIO controls what gh run list / gh run view return:
    #   "pass"    - all workflows completed successfully
    #   "fail"    - one workflow failed
    #   "none"    - no CI workflows (empty array)
    export MOCK_CI_SCENARIO="pass"
    # Counter file for UNKNOWN retry tests
    export MOCK_UNKNOWN_COUNTER_FILE="$MOCK_BIN/.unknown_counter"
    # How many UNKNOWN responses before switching to MOCK_UNKNOWN_FINAL
    export MOCK_UNKNOWN_COUNT=3
    # What to return after UNKNOWN retries exhaust
    export MOCK_UNKNOWN_FINAL="CONFLICTING"

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
    # This mock handles pr view, run list, and run view based on env vars.
    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash

# --- gh pr view ---
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    mergeable="$MOCK_MERGEABLE"

    # Handle UNKNOWN retry logic
    if [[ "$mergeable" == "UNKNOWN" ]]; then
        counter=0
        if [[ -f "$MOCK_UNKNOWN_COUNTER_FILE" ]]; then
            counter=$(cat "$MOCK_UNKNOWN_COUNTER_FILE")
        fi
        counter=$((counter + 1))
        echo "$counter" > "$MOCK_UNKNOWN_COUNTER_FILE"
        if [[ "$counter" -gt "$MOCK_UNKNOWN_COUNT" ]]; then
            mergeable="$MOCK_UNKNOWN_FINAL"
        fi
    fi

    # Handle NO_PR: simulate gh pr view failing (no PR exists)
    if [[ "$mergeable" == "NO_PR" ]]; then
        echo "no pull requests found" >&2
        exit 1
    fi

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
        timeout)
            echo '[{"databaseId":1,"status":"in_progress","conclusion":"","name":"CI","headSha":"abc123"}]'
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
    # Ensure real jq is accessible. We find it outside the mock dir.
    REAL_JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
    if [[ ! -x "$REAL_JQ" ]]; then
        # Try common locations
        for p in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
            if [[ -x "$p" ]]; then
                REAL_JQ="$p"
                break
            fi
        done
    fi
    ln -sf "$REAL_JQ" "$MOCK_BIN/jq"

    # --- Patch the script: set small MAX_ITERATIONS and POLL_INTERVAL=0 ---
    # We create a patched copy to avoid modifying the original.
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

@test "CI fails + conflicts -> exit 1, output contains both 'CI failed' and 'merge conflicts'" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI failed"* ]]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "UNKNOWN retries then CONFLICTING -> exit 1" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="UNKNOWN"
    export MOCK_UNKNOWN_COUNT=2
    export MOCK_UNKNOWN_FINAL="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "UNKNOWN retries then MERGEABLE -> exit 0" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="UNKNOWN"
    export MOCK_UNKNOWN_COUNT=2
    export MOCK_UNKNOWN_FINAL="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
}

@test "No PR exists (gh pr view fails) -> skip conflict check, behave normally" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="NO_PR"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
}

@test "CI timeout + conflicts -> exit 1, output contains both 'timed out' and 'merge conflicts'" {
    export MOCK_MERGEABLE="CONFLICTING"
    export MOCK_CI_SCENARIO="timeout"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out"* ]]
    [[ "$output" == *"merge conflicts"* ]]
}
