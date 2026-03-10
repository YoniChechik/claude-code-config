#!/usr/bin/env bats

# Tests for setup_project_env.sh.
# Mocks uv and npm via a temp PATH dir with marker files.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/skills/create-clone/setup_project_env.sh"

setup() {
    # Create temp dir for mock binaries and prepend to PATH
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # Create working directory for the script to run in
    WORK_DIR="$(mktemp -d)"

    # --- Mock: uv (writes marker file) ---
    cat > "$MOCK_BIN/uv" <<MOCK_UV
#!/usr/bin/env bash
touch "$MOCK_BIN/uv_called"
MOCK_UV
    chmod +x "$MOCK_BIN/uv"

    # --- Mock: npm (writes marker file) ---
    cat > "$MOCK_BIN/npm" <<MOCK_NPM
#!/usr/bin/env bash
touch "$MOCK_BIN/npm_called"
MOCK_NPM
    chmod +x "$MOCK_BIN/npm"
}

teardown() {
    rm -rf "$MOCK_BIN"
    rm -rf "$WORK_DIR"
}

# ---------- Test Cases ----------

@test "pyproject.toml exists -> detects Python project, uv called" {
    touch "$WORK_DIR/pyproject.toml"

    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected Python project"* ]]
    [ -f "$MOCK_BIN/uv_called" ]
}

@test "package-lock.json exists -> detects npm project, npm called" {
    touch "$WORK_DIR/package-lock.json"

    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected npm project"* ]]
    [ -f "$MOCK_BIN/npm_called" ]
}

@test "Both files exist -> both detected, both commands called" {
    touch "$WORK_DIR/pyproject.toml"
    touch "$WORK_DIR/package-lock.json"

    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected Python project"* ]]
    [[ "$output" == *"Detected npm project"* ]]
    [ -f "$MOCK_BIN/uv_called" ]
    [ -f "$MOCK_BIN/npm_called" ]
}

@test "Neither file exists -> exit 0, no detection output" {
    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Detected Python project"* ]]
    [[ "$output" != *"Detected npm project"* ]]
}

@test "Only pyproject.toml -> npm NOT called" {
    touch "$WORK_DIR/pyproject.toml"

    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected Python project"* ]]
    [ -f "$MOCK_BIN/uv_called" ]
    [ ! -f "$MOCK_BIN/npm_called" ]
}

@test "Only package-lock.json -> uv NOT called" {
    touch "$WORK_DIR/package-lock.json"

    run bash -c "cd '$WORK_DIR' && '$SCRIPT_PATH'"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected npm project"* ]]
    [ -f "$MOCK_BIN/npm_called" ]
    [ ! -f "$MOCK_BIN/uv_called" ]
}
