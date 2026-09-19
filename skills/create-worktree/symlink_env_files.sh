#!/usr/bin/env bash
# Symlink .env* files from the repository checkout into a worktree.
# Usage: symlink_env_files.sh <source-repo-dir> <target-worktree-dir>

set -euo pipefail

SOURCE_DIR="${1:-}"
TARGET_DIR="${2:-}"

if [ -z "$SOURCE_DIR" ] || [ -z "$TARGET_DIR" ]; then
    echo "Error: source and target directories are required" >&2
    echo "Usage: $0 <source-repo-dir> <target-worktree-dir>" >&2
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

found_any=0
echo "Symlinking .env* files from $SOURCE_DIR to $TARGET_DIR:"

while IFS= read -r -d '' source_file; do
    found_any=1
    rel_path="${source_file#$SOURCE_DIR/}"
    target_file="$TARGET_DIR/$rel_path"
    mkdir -p "$(dirname "$target_file")"
    rm -f "$target_file"
    ln -s "$source_file" "$target_file"
    echo "  $rel_path -> $source_file"
done < <(find "$SOURCE_DIR" \
    -path '*/.git' -prune -o \
    -path '*/node_modules' -prune -o \
    -path '*/venv' -prune -o \
    -path '*/.venv' -prune -o \
    -path '*/__pycache__' -prune -o \
    -path '*/.claude/worktrees' -prune -o \
    -path '*/.worktrees' -prune -o \
    -name '.env*' ! -name '*.example' ! -name '*.tpl' ! -name '*.tpl.*' ! -name '*.keyshelf' ! -name '*.keyshelf.*' \
    -type f -print0 2>/dev/null)

if [ "$found_any" -eq 0 ]; then
    echo "No .env* files found in $SOURCE_DIR"
fi
