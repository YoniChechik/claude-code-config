#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

if [[ ! "$file_path" =~ \.md$ ]]; then
    exit 0
fi

if [ ! -f "$file_path" ]; then
    exit 0
fi

npx --yes markdown-table-formatter "$file_path" || true
