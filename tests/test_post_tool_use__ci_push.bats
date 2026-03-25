#!/usr/bin/env bats

# Tests for post_tool_use__ci_push.sh hook.
# Mocks git, gh via a temp PATH dir; uses real jq (symlinked).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/post_tool_use__ci_push.sh"

setup() {
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # --- Default mock config via env vars ---
    export MOCK_BRANCH="test-branch"
    export MOCK_PR_EXISTS="yes"
    export MOCK_CI_RUNS="yes"

    # --- Mock: git ---
    cat > "$MOCK_BIN/git" <<'MOCK_GIT'
#!/usr/bin/env bash
if [[ "$1" == "rev-parse" && "$2" == "--abbrev-ref" ]]; then
    echo "$MOCK_BRANCH"
    exit 0
fi
echo "git mock: unhandled command: $*" >&2
exit 1
MOCK_GIT
    chmod +x "$MOCK_BIN/git"

    # --- Mock: gh ---
    cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash

# gh pr view <branch> --json number
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ "$MOCK_PR_EXISTS" == "yes" ]]; then
        echo '{"number":42}'
        exit 0
    fi
    echo "no pull requests found" >&2
    exit 1
fi

# gh run list --limit 1 --json databaseId
if [[ "$1" == "run" && "$2" == "list" ]]; then
    if [[ "$MOCK_CI_RUNS" == "yes" ]]; then
        echo '[{"databaseId":1}]'
    else
        echo '[]'
    fi
    exit 0
fi

echo "gh mock: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$MOCK_BIN/gh"

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
    rm -rf "$MOCK_BIN"
}

# ---------- Trigger Detection ----------

@test "git push + PR exists + CI runs -> outputs hookSpecificOutput JSON" {
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookSpecificOutput"'* ]]
}

@test "gh pr create + PR exists + CI runs -> outputs hookSpecificOutput JSON" {
    local json='{"tool_input":{"command":"gh pr create --title test"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookSpecificOutput"'* ]]
}

@test "command without git push or gh pr create -> exit 0, no output" {
    local json='{"tool_input":{"command":"ls -la"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git push but no PR -> exit 0, no output" {
    export MOCK_PR_EXISTS="no"
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git push + PR exists but no CI runs -> exit 0, no output" {
    export MOCK_CI_RUNS="no"
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------- Updated Hook Behavior ----------

@test "output references ci_watch_persistent.sh (not ci_watch.sh)" {
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ci_watch_persistent.sh"* ]]
}

@test "output contains REMINDER (not BLOCKING REQUIREMENT)" {
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REMINDER"* ]]
    # Ensure it does NOT contain the old blocking language
    [[ "$output" != *"BLOCKING REQUIREMENT"* ]]
    [[ "$output" != *"You MUST"* ]]
}

@test "output contains branch name" {
    export MOCK_BRANCH="my-feature-branch"
    local json='{"tool_input":{"command":"git push origin main"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"my-feature-branch"* ]]
}
