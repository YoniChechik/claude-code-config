#!/usr/bin/env bash
# Symlink .env* files from source repo to target worktree
# Usage: symlink_env_files.sh <source_repo_dir> <target_worktree_dir>

set -e

SOURCE_DIR="$1"
TARGET_DIR="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$TARGET_DIR" ]; then
    echo "Error: Both source_repo_dir and target_worktree_dir are required"
    echo "Usage: $0 <source_repo_dir> <target_worktree_dir>"
    exit 1
fi

SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

# Build the find command once. It emits matches NUL-separated (-print0) so the
# read loop below is space-safe and never word-splits on whitespace in paths.
# Process substitution (not a pipe) keeps the loop body in the current shell, so
# the linked counter survives after the loop.
find_env_files() {
    find "$SOURCE_DIR" \
        -path "*/.git" -prune -o \
        -path "*/node_modules" -prune -o \
        -path "*/venv" -prune -o \
        -path "*/.venv" -prune -o \
        -path "*/__pycache__" -prune -o \
        -path "*/_worktrees" -prune -o \
        -name ".env*" ! -name "*.example" ! -name "*.tpl" ! -name "*.tpl.*" ! -name "*.keyshelf" ! -name "*.keyshelf.*" -type f -print0 2>/dev/null
}

echo "Symlinking .env* files from $SOURCE_DIR to $TARGET_DIR:"

# Iterate NUL-delimited records so paths containing spaces survive intact.
linked=0
while IFS= read -r -d '' SOURCE_FILE; do
    REL_PATH="${SOURCE_FILE#$SOURCE_DIR/}"
    TARGET_FILE="$TARGET_DIR/$REL_PATH"

    mkdir -p "$(dirname "$TARGET_FILE")"

    if [ -e "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
        rm "$TARGET_FILE"
    fi

    ln -s "$SOURCE_FILE" "$TARGET_FILE"
    echo "  $REL_PATH -> $SOURCE_FILE"
    linked=$((linked + 1))
done < <(find_env_files)

# Report when nothing matched (after the loop, since the loop drives detection).
if [ "$linked" -eq 0 ]; then
    echo "No .env* files found in $SOURCE_DIR"
fi
