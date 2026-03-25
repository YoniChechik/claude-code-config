#!/usr/bin/env bats

# Tests for ci_watch_persistent.sh (simplified flat-loop CI watcher).
#
# The script runs a single while-true loop and only exits on:
#   - No branch argument (exit 1)
#   - CI failure (exit 1)
#   - Merge conflict (exit 1)
#
# For "CI passes" tests, we use a sleep mock with a counter that kills the
# script process after N iterations, since the script never exits on pass.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CI_WATCH="$SCRIPT_DIR/scripts/ci_watch_persistent.sh"

setup() {
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # --- State files ---
    export GH_RUN_LIST_CALL_COUNT_FILE="$MOCK_BIN/.gh_run_list_calls"
    echo "0" > "$GH_RUN_LIST_CALL_COUNT_FILE"

    # --- Default mock config ---
    export MOCK_MERGEABLE="MERGEABLE"
    # MOCK_CI_SCENARIO: pass, fail, none, in_progress
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
if [[ "$1" == "rev-parse" ]]; then
    echo "abc123"
    exit 0
fi
command git "$@"
MOCK_GIT
    chmod +x "$MOCK_BIN/git"

    # --- Mock: gh ---
    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash

# --- gh pr view ---
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ "$MOCK_MERGEABLE" == "NO_PR" ]]; then
        echo "no pull requests found" >&2
        exit 1
    fi
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            echo "$MOCK_MERGEABLE"
            exit 0
        fi
    done
    echo "{\"mergeable\":\"$MOCK_MERGEABLE\"}"
    exit 0
fi

# --- gh run list ---
if [[ "$1" == "run" && "$2" == "list" ]]; then
    # Track call count
    COUNT=$(cat "$GH_RUN_LIST_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$GH_RUN_LIST_CALL_COUNT_FILE"

    # Determine scenario - allow per-call overrides via MOCK_CI_SCENARIO_CALL_N
    VARNAME="MOCK_CI_SCENARIO_CALL_${COUNT}"
    SCENARIO="${!VARNAME:-$MOCK_CI_SCENARIO}"

    case "$SCENARIO" in
        pass)
            echo '[{"databaseId":100,"status":"completed","conclusion":"success","name":"CI","headSha":"abc123"}]'
            ;;
        fail)
            echo '[{"databaseId":200,"status":"completed","conclusion":"failure","name":"CI","headSha":"abc123"}]'
            ;;
        fail_multi)
            echo '[{"databaseId":200,"status":"completed","conclusion":"failure","name":"Lint","headSha":"abc123"},{"databaseId":201,"status":"completed","conclusion":"failure","name":"Test","headSha":"abc123"}]'
            ;;
        none)
            echo '[]'
            ;;
        in_progress)
            echo '[{"databaseId":100,"status":"in_progress","conclusion":"","name":"CI","headSha":"abc123"}]'
            ;;
        new_sha_pass)
            echo '[{"databaseId":300,"status":"completed","conclusion":"success","name":"CI","headSha":"def456"}]'
            ;;
        new_sha_fail)
            echo '[{"databaseId":300,"status":"completed","conclusion":"failure","name":"CI","headSha":"def456"}]'
            ;;
        new_sha2_fail)
            echo '[{"databaseId":400,"status":"completed","conclusion":"failure","name":"CI","headSha":"ghi789"}]'
            ;;
        dedup)
            echo '[{"databaseId":100,"status":"completed","conclusion":"failure","name":"CI","headSha":"abc123"},{"databaseId":200,"status":"completed","conclusion":"success","name":"CI","headSha":"abc123"}]'
            ;;
    esac
    exit 0
fi

# --- gh run view ---
if [[ "$1" == "run" && "$2" == "view" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "-q" || "$arg" == "--jq" ]]; then
            echo "build"
            exit 0
        fi
    done
    echo '{"jobs":[{"name":"build","conclusion":"failure"}]}'
    exit 0
fi

echo "gh mock: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$MOCK_BIN/gh"

    # --- Symlink real jq and paste ---
    REAL_JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
    if [[ ! -x "$REAL_JQ" ]]; then
        for p in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
            [[ -x "$p" ]] && REAL_JQ="$p" && break
        done
    fi
    ln -sf "$REAL_JQ" "$MOCK_BIN/jq"

    REAL_PASTE="$(command -v paste 2>/dev/null || echo /usr/bin/paste)"
    [[ -x "$REAL_PASTE" ]] && ln -sf "$REAL_PASTE" "$MOCK_BIN/paste"

    # --- Patch script: POLL_INTERVAL=0 ---
    PATCHED_SCRIPT="$MOCK_BIN/ci_watch_patched.sh"
    sed 's/^POLL_INTERVAL=.*/POLL_INTERVAL=0/' "$CI_WATCH" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    rm -rf "$MOCK_BIN"
}

# ========== No branch argument ==========

@test "no branch argument -> exit 1 with usage message" {
    run "$MOCK_BIN/ci_watch_patched.sh"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# ========== CI Failure ==========

@test "CI failure -> exit 1 with failure details" {
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI failed"* ]]
}

@test "CI failure includes workflow names in output" {
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"workflows: CI"* ]]
}

@test "CI failure includes failed job names in output" {
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed jobs:"*"build"* ]]
}

@test "CI failure output includes relaunch instruction" {
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"First relaunch the CI watcher"* ]]
}

@test "CI failure output includes gh run view command" {
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh run view"* ]]
    [[ "$output" == *"--log-failed"* ]]
}

# ========== Merge Conflict ==========

@test "merge conflict -> exit 1 with conflict message" {
    export MOCK_MERGEABLE="CONFLICTING"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

@test "merge conflict without CI runs -> exit 1" {
    export MOCK_MERGEABLE="CONFLICTING"
    export MOCK_CI_SCENARIO="none"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
    [[ "$output" == *"First relaunch"* ]]
}

@test "merge conflict takes precedence over CI failure" {
    export MOCK_MERGEABLE="CONFLICTING"
    export MOCK_CI_SCENARIO="fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
}

# ========== CI Passes ==========

@test "CI passes -> output includes CI passed message" {
    # Pass on call 1, then new SHA with failure on call 2+ to exit the script.
    export MOCK_CI_SCENARIO="pass"
    export MOCK_CI_SCENARIO_CALL_2="new_sha_fail"
    export MOCK_CI_SCENARIO_CALL_3="new_sha_fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI passed"* ]]
    [[ "$output" == *"All workflows green"* ]]
}

# ========== CI passes then new push with failure ==========

@test "CI passes then new push with failure -> exit 1, output includes both CI passed and failure" {
    # Call 1: pass (CI passes, REPORTED_PASS set)
    # Call 2: new SHA with pass (triggers "New push detected", resets REPORTED_PASS)
    # Call 3: new SHA with failure (CI fails on new SHA -> exit 1)
    export MOCK_CI_SCENARIO="pass"
    export MOCK_CI_SCENARIO_CALL_2="new_sha_fail"
    export MOCK_CI_SCENARIO_CALL_3="new_sha_fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI passed"* ]]
    [[ "$output" == *"New push detected"* ]]
    [[ "$output" == *"CI failed"* ]]
}

# ========== New SHA mid-poll ==========

@test "new SHA mid-poll -> detects and reports new push" {
    # Call 1: new_sha_pass (headSha=def456 differs from abc123 -> "New push detected", CI passes)
    # Call 2+: yet another SHA (ghi789) with failure -> "New push detected" again, then exit 1
    export MOCK_CI_SCENARIO="new_sha_pass"
    export MOCK_CI_SCENARIO_CALL_2="new_sha2_fail"
    export MOCK_CI_SCENARIO_CALL_3="new_sha2_fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"New push detected"* ]]
    [[ "$output" == *"new SHA: def456"* ]]
}

# ========== Dedup by workflow ==========

@test "dedup by workflow: multiple runs same workflow, keeps latest" {
    # Two runs for workflow "CI": databaseId 100 (failure) and 200 (success).
    # After dedup, only databaseId 200 (success) should be kept -> CI passes.
    # Then new SHA with failure on call 2+ to exit.
    export MOCK_CI_SCENARIO="dedup"
    export MOCK_CI_SCENARIO_CALL_2="new_sha_fail"
    export MOCK_CI_SCENARIO_CALL_3="new_sha_fail"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    # Should pass on first cycle because the latest run (id 200) is success
    [[ "$output" == *"CI passed"* ]]
}

# ========== No CI runs keeps polling ==========

@test "no CI runs -> script keeps polling, does not exit immediately" {
    # No runs for first 2 calls, then merge conflict on 3rd to exit.
    # This proves the script kept polling through empty results.
    export MOCK_CI_SCENARIO="none"
    # After 2 calls with no runs, switch to conflict to exit
    export MOCK_CI_SCENARIO_CALL_3="pass"
    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash

if [[ "$1" == "pr" && "$2" == "view" ]]; then
    COUNT=$(cat "$GH_RUN_LIST_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    # After run list has been called 2+ times, return CONFLICTING to exit
    if [ "$COUNT" -ge 2 ]; then
        for arg in "$@"; do
            [[ "$arg" == "--jq" ]] && echo "CONFLICTING" && exit 0
        done
        echo '{"mergeable":"CONFLICTING"}'
        exit 0
    fi
    for arg in "$@"; do
        [[ "$arg" == "--jq" ]] && echo "MERGEABLE" && exit 0
    done
    echo '{"mergeable":"MERGEABLE"}'
    exit 0
fi

if [[ "$1" == "run" && "$2" == "list" ]]; then
    COUNT=$(cat "$GH_RUN_LIST_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$GH_RUN_LIST_CALL_COUNT_FILE"
    echo '[]'
    exit 0
fi

echo "gh mock: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$MOCK_BIN/gh"

    run "$MOCK_BIN/ci_watch_patched.sh" "test-branch"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge conflicts"* ]]
    # Proves it didn't exit on empty runs - it kept polling until conflict
    [[ "$output" != *"CI passed"* ]]
    [[ "$output" != *"CI failed"* ]]
}
