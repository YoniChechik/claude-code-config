#!/usr/bin/env bats

# Tests for pre_tool_use__base_dir_protect.sh hook.
# Verifies that git write ops and file edits are blocked outside _clones/.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/pre_tool_use__base_dir_protect.sh"

setup() {
    # Create temp dir for mock binaries and prepend to PATH
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

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

    # Shared temp dir for tests that need filesystem fixtures
    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$MOCK_BIN"
    rm -rf "$TEST_TMPDIR"
}

# ---------- Bash tool tests ----------

@test "Bash: git add inside _clones/ -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"git add ."},"cwd":"/Users/me/_clones/my-repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Bash: git commit outside _clones/ -> blocked (permissionDecision=ask)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"git commit -m fix"},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"ask"'* ]]
    [[ "$output" == *'Git write operation outside _clones directory'* ]]
}

@test "Bash: git push outside _clones/ -> blocked (permissionDecision=ask)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"git push origin main"},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"ask"'* ]]
}

@test "Bash: non-git command (ls) outside _clones/ -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Bash: empty command -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Bash","tool_input":{"command":""},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Bash: git log (read-only) outside _clones/ -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"git log --oneline"},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Bash: git status (read-only) outside _clones/ -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"/Users/me/projects/repo"}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------- Edit/Write tool tests ----------

@test "Edit: file inside _clones/ with .git ancestor -> allowed (exit 0, no output)" {
    # Create a dir structure simulating _clones/ with a git repo
    mkdir -p "$TEST_TMPDIR/_clones/repo/.git"
    mkdir -p "$TEST_TMPDIR/_clones/repo/src"
    touch "$TEST_TMPDIR/_clones/repo/src/file.py"

    local file_path="$TEST_TMPDIR/_clones/repo/src/file.py"
    local json='{"tool_name":"Edit","tool_input":{"file_path":"'"$file_path"'"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Write: file outside _clones/ inside git repo -> blocked (permissionDecision=ask)" {
    # Create a dir structure simulating a git repo outside _clones/
    mkdir -p "$TEST_TMPDIR/projects/repo/.git"
    mkdir -p "$TEST_TMPDIR/projects/repo/src"
    touch "$TEST_TMPDIR/projects/repo/src/file.py"

    local file_path="$TEST_TMPDIR/projects/repo/src/file.py"
    local json='{"tool_name":"Write","tool_input":{"file_path":"'"$file_path"'"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"ask"'* ]]
    [[ "$output" == *'File edit outside _clones directory'* ]]
}

@test "Edit: file outside any git repo -> allowed (exit 0, no output)" {
    # Dir with no .git anywhere
    mkdir -p "$TEST_TMPDIR/notes"
    touch "$TEST_TMPDIR/notes/todo.txt"

    local file_path="$TEST_TMPDIR/notes/todo.txt"
    local json='{"tool_name":"Edit","tool_input":{"file_path":"'"$file_path"'"}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Edit: empty file_path -> allowed (exit 0, no output)" {
    local json='{"tool_name":"Edit","tool_input":{"file_path":""}}'

    run bash -c 'echo "$1" | "$2"' -- "$json" "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
