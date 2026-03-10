#!/usr/bin/env bats

# Tests for symlink_env_files.sh.
# Uses real filesystem ops (temp dirs) — no mocking needed.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/skills/create-clone/symlink_env_files.sh"

setup() {
    SOURCE_DIR="$(mktemp -d)"
    TARGET_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$SOURCE_DIR" "$TARGET_DIR"
}

# ---------- Basic symlinking ----------

@test "Source with .env file -> symlink created in target, is valid symlink" {
    echo "SECRET=123" > "$SOURCE_DIR/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.env" ]
    [ "$(readlink "$TARGET_DIR/.env")" = "$SOURCE_DIR/.env" ]
    [ "$(cat "$TARGET_DIR/.env")" = "SECRET=123" ]
}

@test "Source with .env.local -> symlink created" {
    echo "LOCAL=yes" > "$SOURCE_DIR/.env.local"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.env.local" ]
    [ "$(readlink "$TARGET_DIR/.env.local")" = "$SOURCE_DIR/.env.local" ]
}

# ---------- Exclusions ----------

@test "Source with .env.example -> NOT symlinked (excluded)" {
    echo "EXAMPLE=1" > "$SOURCE_DIR/.env.example"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.env.example" ]
    [[ "$output" == *"No .env* files found"* ]]
}

@test "Source with .env.tpl -> NOT symlinked (excluded)" {
    echo "TPL=1" > "$SOURCE_DIR/.env.tpl"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.env.tpl" ]
    [[ "$output" == *"No .env* files found"* ]]
}

# ---------- Pruned directories ----------

@test "Source with .env in node_modules/ -> NOT symlinked (pruned)" {
    mkdir -p "$SOURCE_DIR/node_modules"
    echo "NM=1" > "$SOURCE_DIR/node_modules/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/node_modules/.env" ]
    [[ "$output" == *"No .env* files found"* ]]
}

@test "Source with .env in .git/ -> NOT symlinked (pruned)" {
    mkdir -p "$SOURCE_DIR/.git"
    echo "GIT=1" > "$SOURCE_DIR/.git/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.git/.env" ]
    [[ "$output" == *"No .env* files found"* ]]
}

@test "Source with .env in venv/ -> NOT symlinked (pruned)" {
    mkdir -p "$SOURCE_DIR/venv"
    echo "VENV=1" > "$SOURCE_DIR/venv/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/venv/.env" ]
    [[ "$output" == *"No .env* files found"* ]]
}

@test "Source with .env in _clones/ -> NOT symlinked (pruned)" {
    mkdir -p "$SOURCE_DIR/_clones"
    echo "CLONES=1" > "$SOURCE_DIR/_clones/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/_clones/.env" ]
    [[ "$output" == *"No .env* files found"* ]]
}

# ---------- Nested files ----------

@test "Nested .env file (sub/dir/.env.production) -> symlink with correct path, parent dirs created" {
    mkdir -p "$SOURCE_DIR/sub/dir"
    echo "PROD=1" > "$SOURCE_DIR/sub/dir/.env.production"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/sub/dir/.env.production" ]
    [ "$(readlink "$TARGET_DIR/sub/dir/.env.production")" = "$SOURCE_DIR/sub/dir/.env.production" ]
    [ -d "$TARGET_DIR/sub/dir" ]
}

# ---------- No env files ----------

@test "No .env files -> exit 0, output 'No .env* files found'" {
    touch "$SOURCE_DIR/README.md"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No .env* files found"* ]]
}

# ---------- Missing arguments ----------

@test "Missing source_dir argument -> exit 1" {
    run bash "$SCRIPT"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

@test "Missing target_dir argument -> exit 1" {
    run bash "$SCRIPT" "$SOURCE_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

# ---------- Replacement behavior ----------

@test "Target already has existing file -> replaced with symlink" {
    echo "SECRET=123" > "$SOURCE_DIR/.env"
    echo "OLD_CONTENT" > "$TARGET_DIR/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.env" ]
    [ "$(readlink "$TARGET_DIR/.env")" = "$SOURCE_DIR/.env" ]
    [ "$(cat "$TARGET_DIR/.env")" = "SECRET=123" ]
}

@test "Target already has existing symlink -> replaced with new symlink" {
    echo "SECRET=123" > "$SOURCE_DIR/.env"
    # Create a dangling symlink at target
    ln -s "/nonexistent/path" "$TARGET_DIR/.env"

    run bash "$SCRIPT" "$SOURCE_DIR" "$TARGET_DIR"

    echo "OUTPUT: $output"
    echo "STATUS: $status"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.env" ]
    [ "$(readlink "$TARGET_DIR/.env")" = "$SOURCE_DIR/.env" ]
    [ "$(cat "$TARGET_DIR/.env")" = "SECRET=123" ]
}
