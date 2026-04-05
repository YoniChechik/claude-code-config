#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

if [[ ! "$file_path" =~ \.(js|jsx|ts|tsx)$ ]]; then
    exit 0
fi

if [ ! -f "$file_path" ]; then
    exit 0
fi

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

if [ -x "$project_root/node_modules/.bin/eslint" ]; then
    "$project_root/node_modules/.bin/eslint" --fix "$file_path" 2>&1 || true
fi

if [ -x "$project_root/node_modules/.bin/prettier" ]; then
    "$project_root/node_modules/.bin/prettier" --write "$file_path" 2>&1 || true
fi
