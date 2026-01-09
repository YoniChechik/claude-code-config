#!/usr/bin/env bash
set -euo pipefail

# Post-edit hook for running ruff on Python files
# Receives tool arguments as JSON via stdin

# Read the arguments JSON from stdin
input=$(cat)

# Extract file_path from the JSON arguments
# For Edit tool, the file_path is in the arguments
file_path=$(echo "$input" | jq -r '.arguments.file_path // empty')

# If file_path is empty, exit silently
if [ -z "$file_path" ]; then
    exit 0
fi

# Only process Python files
if [[ ! "$file_path" =~ \.py$ ]]; then
    exit 0
fi

# Check if file exists
if [ ! -f "$file_path" ]; then
    exit 0
fi

# Run ruff format
uv run ruff format "$file_path" 2>&1 || true

# Run ruff check with auto-fix and unsafe fixes
uv run ruff check --fix --unsafe-fixes "$file_path" 2>&1 || true
