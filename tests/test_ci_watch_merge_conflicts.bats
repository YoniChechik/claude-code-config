#!/usr/bin/env bats

# Tests for ci_watch_persistent.sh (CI watcher).
# Mocks all external commands (gh, git, jq, sleep, date) via a temp PATH dir.
#
# Exit behavior:
#   - CI passed: does NOT exit immediately, enters wait-for-new-SHA loop.
#     Tests use the date mock inactivity timeout to eventually cause exit 0.
#   - CI failed/timeout/conflict: exits immediately with code 1.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CI_WATCH="$SCRIPT_DIR/scripts/ci_watch_persistent.sh"

setup() {
    # Create temp dir for mock binaries and prepend to PATH
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # State file: date mock uses this to know when to return future time
    export DATE_CALL_COUNT_FILE="$MOCK_BIN/.date_call_count"
    echo "0" > "$DATE_CALL_COUNT_FILE"
    # After this many date calls, return a time far in the future to trigger inactivity timeout
    export DATE_FUTURE_AFTER="${DATE_FUTURE_AFTER:-6}"

    # --- Default mock config via env vars ---
    # MOCK_MERGEABLE controls gh pr view response: MERGEABLE, CONFLICTING, or NO_PR
    export MOCK_MERGEABLE="MERGEABLE"
    # MOCK_CI_SCENARIO controls what gh run list / gh run view return:
    #   "pass"       - all workflows completed successfully
    #   "fail"       - one workflow failed
    #   "none"       - no CI workflows (empty array)
    #   "superseded" - latest run has a different SHA (newer push)
    export MOCK_CI_SCENARIO="pass"

    # --- Mock: sleep (no-op) ---
    cat > "$MOCK_BIN/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$MOCK_BIN/sleep"

    # --- Mock: date ---
    # Returns real time for the first N calls, then returns a time 2 hours in the future
    # to trigger the inactivity timeout.
    cat > "$MOCK_BIN/date" <<'MOCK_DATE'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s" ]]; then
    COUNT=$(cat "$DATE_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$DATE_CALL_COUNT_FILE"
    if [ "$COUNT" -gt "$DATE_FUTURE_AFTER" ]; then
        # Return a time 2 hours in the future from a base time
        echo "9999999999"
    else
        # Return a normal base time
        echo "1000000"
    fi
else
    command date "$@"
fi
MOCK_DATE
    chmod +x "$MOCK_BIN/date"

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
    # Check for --jq flag (used in wait-for-new-SHA loop)
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            case "$MOCK_CI_SCENARIO" in
                pass)       echo "abc123" ;;
                fail)       echo "abc123" ;;
                none)       echo "" ;;
                superseded) echo "def456" ;;
            esac
            exit 0
        fi
    done

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
        superseded)
            echo '[{"databaseId":300,"status":"completed","conclusion":"success","name":"CI","headSha":"def456"}]'
            ;;
    esac
    exit 0
fi

# --- gh run view ---
if [[ "$1" == "run" && "$2" == "view" ]]; then
    # Check if -q flag is present (jq filter mode) — return filtered output
    for arg in "$@"; do
        if [[ "$arg" == "-q" || "$arg" == "--jq" ]]; then
            echo "build"
            exit 0
        fi
    done
    # No -q flag: return raw JSON
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

    # --- Mock: paste (macOS paste may not be in PATH inside mock) ---
    REAL_PASTE="$(command -v paste 2>/dev/null || echo /usr/bin/paste)"
    if [[ -x "$REAL_PASTE" ]]; then
        ln -sf "$REAL_PASTE" "$MOCK_BIN/paste"
    fi

    # --- Patch the script: set small CI_RUN_MAX_ITERATIONS, POLL_INTERVAL=0, INACTIVITY_TIMEOUT=1 ---
    PATCHED_SCRIPT="$MOCK_BIN/ci_watch_patched.sh"
    sed \
        -e 's/^POLL_INTERVAL=.*/POLL_INTERVAL=0/' \
        -e 's/^CI_RUN_TIMEOUT=.*/CI_RUN_TIMEOUT=0/' \
        -e 's|^CI_RUN_MAX_ITERATIONS=.*|CI_RUN_MAX_ITERATIONS=4|' \
        -e 's/^INACTIVITY_TIMEOUT=.*/INACTIVITY_TIMEOUT=1/' \
        "$CI_WATCH" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    rm -rf "$MOCK_BIN"
}

# Helper: set up a CI run timeout scenario (in-progress runs that never complete)
_setup_ci_run_timeout_test() {
    PATCHED_TIMEOUT="$MOCK_BIN/ci_watch_timeout.sh"
    sed \
        -e 's/^POLL_INTERVAL=.*/POLL_INTERVAL=0/' \
        -e 's/^CI_RUN_TIMEOUT=.*/CI_RUN_TIMEOUT=0/' \
        -e 's|^CI_RUN_MAX_ITERATIONS=.*|CI_RUN_MAX_ITERATIONS=1|' \
        -e 's/^INACTIVITY_TIMEOUT=.*/INACTIVITY_TIMEOUT=1/' \
        "$CI_WATCH" > "$PATCHED_TIMEOUT"
    chmod +x "$PATCHED_TIMEOUT"

    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            echo "MERGEABLE"
            exit 0
        fi
    done
    echo '{"mergeable":"MERGEABLE"}'
    exit 0
fi
if [[ "$1" == "run" && "$2" == "list" ]]; then
    # Check for --jq flag (used in wait-for-new-SHA loop)
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            echo "abc123"
            exit 0
        fi
    done
    echo '[{"databaseId":100,"status":"in_progress","conclusion":"","name":"CI","headSha":"abc123"}]'
    exit 0
fi
echo "gh mock: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$MOCK_BIN/gh"
}

# ---------- Edge Cases ----------

@test "no branch argument -> exit 1 with usage message" {
    run "$MOCK_BIN/ci_watch_patched.sh"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# ---------- CI Pass (watcher continues) ----------

@test "CI passes -> exit 0 (inactivity), output contains 'CI passed' and 'Waiting for new push'" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
    [[ "$output" == *"All workflows green"* ]]
    [[ "$output" == *"Waiting for new push"* ]]
    [[ "$output" == *"Exiting watcher"* ]]
}

@test "No PR exists -> CI passes, watcher continues" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="NO_PR"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI passed"* ]]
    [[ "$output" == *"Waiting for new push"* ]]
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

# ---------- CI Failure (watcher exits 1) ----------

@test "CI fails -> exit 1, output contains 'CI failed' and workflow name" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI failed"* ]]
    [[ "$output" == *"workflows: CI"* ]]
}

@test "CI fails -> output contains 'gh run view' and '--log-failed'" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh run view"* ]]
    [[ "$output" == *"--log-failed"* ]]
}

@test "CI fails -> output contains failed job name 'build'" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed jobs:"*"build"* ]]
}

@test "CI fails -> output contains 'First relaunch' instruction" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"First relaunch the CI watcher"* ]]
    [[ "$output" == *"then delegate the fix to coder-agent"* ]]
}

@test "CI fails -> does NOT enter wait-for-new-SHA loop" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Waiting for new push"* ]]
}

# ---------- Merge Conflicts (watcher exits 1) ----------

@test "Merge conflict (with CI runs) -> exit 1, output contains 'merge conflicts'" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "Merge conflict -> output contains 'First relaunch' instruction" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"First relaunch the CI watcher"* ]]
    [[ "$output" == *"then delegate the fix to coder-agent"* ]]
}

@test "Merge conflict -> does NOT enter wait-for-new-SHA loop" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Waiting for new push"* ]]
}

@test "Merge conflict (no CI workflows) -> exit 1" {
    export MOCK_CI_SCENARIO="none"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
    [[ "$output" == *"First relaunch"* ]]
}

@test "CI fails + conflicts -> conflict takes precedence, exit 1" {
    export MOCK_CI_SCENARIO="fail"
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

# ---------- CI Run Timeout (watcher exits 1) ----------

@test "CI run timeout -> exit 1, output contains 'timed out'" {
    _setup_ci_run_timeout_test

    run "$PATCHED_TIMEOUT" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out"* ]]
}

@test "CI run timeout -> output contains 'First relaunch' instruction" {
    _setup_ci_run_timeout_test

    run "$PATCHED_TIMEOUT" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"First relaunch the CI watcher"* ]]
    [[ "$output" == *"then delegate the fix to coder-agent"* ]]
}

@test "CI run timeout -> does NOT enter wait-for-new-SHA loop" {
    _setup_ci_run_timeout_test

    run "$PATCHED_TIMEOUT" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Waiting for new push"* ]]
}

# ---------- Newer Push (SHA Update) ----------

@test "Newer push detected -> updates tracked SHA, continues polling, and CI passes" {
    export MOCK_CI_SCENARIO="superseded"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"New push detected"* ]]
    [[ "$output" == *"new SHA: def456"* ]]
    [[ "$output" == *"Now tracking new CI run"* ]]
    [[ "$output" == *"CI passed"* ]]
}

# ---------- Inactivity Timeout ----------

@test "Inactivity timeout -> exit 0, output contains 'No new pushes detected' and 'Exiting'" {
    export MOCK_CI_SCENARIO="pass"
    export MOCK_MERGEABLE="MERGEABLE"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No new pushes detected"* ]]
    [[ "$output" == *"Exiting watcher"* ]]
}
