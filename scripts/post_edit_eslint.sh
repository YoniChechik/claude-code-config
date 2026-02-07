#!/usr/bin/env bash
set -euo pipefail

# Post-edit hook for running eslint + prettier on JS/TS/React files
# Receives tool arguments as JSON via stdin

# Read the arguments JSON from stdin
input=$(cat)

# Extract file_path from the JSON arguments
file_path=$(echo "$input" | jq -r '.arguments.file_path // empty')

# If file_path is empty, exit silently
if [ -z "$file_path" ]; then
    exit 0
fi

# Only process JS/TS/JSX/TSX files
if [[ ! "$file_path" =~ \.(js|jsx|ts|tsx)$ ]]; then
    exit 0
fi

# Check if file exists
if [ ! -f "$file_path" ]; then
    exit 0
fi

# Find the project root by walking up to find package.json
dir=$(dirname "$file_path")
project_root=""
while [ "$dir" != "/" ]; do
    if [ -f "$dir/package.json" ]; then
        project_root="$dir"
        break
    fi
    dir=$(dirname "$dir")
done

if [ -z "$project_root" ]; then
    exit 0
fi

# Run eslint --fix if eslint is available in the project
if [ -x "$project_root/node_modules/.bin/eslint" ]; then
    "$project_root/node_modules/.bin/eslint" --fix "$file_path" 2>&1 || true
fi

# Run prettier --write if prettier is available in the project
if [ -x "$project_root/node_modules/.bin/prettier" ]; then
    "$project_root/node_modules/.bin/prettier" --write "$file_path" 2>&1 || true
fi
