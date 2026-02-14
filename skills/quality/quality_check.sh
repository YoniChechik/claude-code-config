#!/bin/bash
# Runs ruff and ty on all Python files changed from main branch
# Usage: ./quality_check.sh [--fix]

set -e

# Get changed Python files
FILES=$(comm -12 \
  <(git diff --name-only main...HEAD -- '*.py' | sort) \
  <(git ls-files -- '*.py' | sort) 2>/dev/null || true)

UNCOMMITTED=$(git diff --name-only -- '*.py' 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard -- '*.py' 2>/dev/null || true)

ALL_FILES=$(echo -e "$FILES\n$UNCOMMITTED\n$UNTRACKED" | sort -u | grep -v '^$' || true)

if [ -z "$ALL_FILES" ]; then
    echo "No Python files changed"
    exit 0
fi

echo "Files to check:"
echo "$ALL_FILES"
echo ""

if [ "$1" = "--fix" ]; then
    echo "=== Running ruff format ==="
    echo "$ALL_FILES" | xargs uv run ruff format

    echo "=== Running ruff check --fix ==="
    echo "$ALL_FILES" | xargs uv run ruff check --fix --unsafe-fixes || true
fi

echo "=== Running ruff check ==="
echo "$ALL_FILES" | xargs uv run ruff check

echo "=== Running ty check ==="
echo "$ALL_FILES" | xargs uv run ty check
