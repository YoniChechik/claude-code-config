#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

if [[ ! "$file_path" =~ \.py$ ]]; then
    exit 0
fi

if [ ! -f "$file_path" ]; then
    exit 0
fi

uv run ruff format "$file_path" 2>&1 || true
uv run ruff check --fix --unsafe-fixes "$file_path" 2>&1 || true
