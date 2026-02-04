#!/usr/bin/env bash

# Symlink .env* files from source repo to target clone
# Usage: symlink_env_files.sh <source_repo_dir> <target_clone_dir>

set -e

SOURCE_DIR="$1"
TARGET_DIR="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$TARGET_DIR" ]; then
    echo "Error: Both source_repo_dir and target_clone_dir are required"
    echo "Usage: $0 <source_repo_dir> <target_clone_dir>"
    exit 1
fi

# Convert to absolute paths
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

# Find all .env* files in source directory (not in subdirectories)
ENV_FILES=$(find "$SOURCE_DIR" -maxdepth 1 -name ".env*" -type f 2>/dev/null)

if [ -z "$ENV_FILES" ]; then
    echo "No .env* files found in $SOURCE_DIR"
    exit 0
fi

echo "Symlinking .env* files from $SOURCE_DIR to $TARGET_DIR:"

for SOURCE_FILE in $ENV_FILES; do
    FILENAME=$(basename "$SOURCE_FILE")
    TARGET_FILE="$TARGET_DIR/$FILENAME"

    # Remove existing file/symlink if present
    if [ -e "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
        rm "$TARGET_FILE"
    fi

    ln -s "$SOURCE_FILE" "$TARGET_FILE"
    echo "  $FILENAME -> $SOURCE_FILE"
done
