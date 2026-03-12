#!/bin/bash
# Runs linting, formatting, and type checks on changed files
# Supports Python (ruff, ty) and JS/TS (eslint, prettier, tsc)
# Usage: ./quality_check.sh [--fix]

FIX_MODE=false
if [ "$1" = "--fix" ]; then
    FIX_MODE=true
fi

EXIT_CODE=0

check_tool() {
    local tool="$1"
    local runner="$2"
    if [ -n "$runner" ]; then
        if ! command -v "$runner" &>/dev/null; then
            echo "SKIP: $runner not found, skipping $tool"
            return 1
        fi
    else
        if ! command -v "$tool" &>/dev/null; then
            echo "SKIP: $tool not found, skipping"
            return 1
        fi
    fi
    return 0
}

get_changed_files() {
    local extensions="$1"

    local branch_files=""
    branch_files=$(comm -12 \
        <(git diff --name-only main...HEAD -- $extensions 2>/dev/null | sort) \
        <(git ls-files -- $extensions 2>/dev/null | sort) 2>/dev/null || true)

    local uncommitted=""
    uncommitted=$(git diff --name-only -- $extensions 2>/dev/null || true)

    local untracked=""
    untracked=$(git ls-files --others --exclude-standard -- $extensions 2>/dev/null || true)

    echo -e "$branch_files\n$uncommitted\n$untracked" | sort -u | grep -v '^$' || true
}

# ============================================================
# Python
# ============================================================

PY_FILES=$(get_changed_files "'*.py'")

if [ -n "$PY_FILES" ]; then
    echo "=== Python files to check ==="
    echo "$PY_FILES"
    echo ""

    if $FIX_MODE; then
        if check_tool "ruff" "uv"; then
            echo "=== Running ruff format ==="
            echo "$PY_FILES" | xargs uv run ruff format

            echo "=== Running ruff check --fix ==="
            echo "$PY_FILES" | xargs uv run ruff check --fix --unsafe-fixes || true
        fi
    fi

    if check_tool "ruff" "uv"; then
        echo "=== Running ruff check ==="
        if ! echo "$PY_FILES" | xargs uv run ruff check; then
            EXIT_CODE=1
        fi
    fi

    if check_tool "ty" "uv"; then
        echo "=== Running ty check ==="
        if ! echo "$PY_FILES" | xargs uv run ty check; then
            EXIT_CODE=1
        fi
    fi
else
    echo "No Python files changed"
fi

echo ""

# ============================================================
# JavaScript / TypeScript
# ============================================================

JS_FILES=$(get_changed_files "'*.ts' '*.tsx' '*.js' '*.jsx'")

if [ -n "$JS_FILES" ]; then
    echo "=== JS/TS files to check ==="
    echo "$JS_FILES"
    echo ""

    if $FIX_MODE; then
        if check_tool "prettier" "npx"; then
            echo "=== Running prettier --write ==="
            echo "$JS_FILES" | xargs npx prettier --write
        fi

        if check_tool "eslint" "npx"; then
            echo "=== Running eslint --fix ==="
            echo "$JS_FILES" | xargs npx eslint --fix || true
        fi
    fi

    if check_tool "eslint" "npx"; then
        echo "=== Running eslint ==="
        if ! echo "$JS_FILES" | xargs npx eslint; then
            EXIT_CODE=1
        fi
    fi

    if [ -f "tsconfig.json" ]; then
        if check_tool "tsc" "npx"; then
            echo "=== Running tsc --noEmit ==="
            if ! npx tsc --noEmit; then
                EXIT_CODE=1
            fi
        fi
    fi
else
    echo "No JS/TS files changed"
fi

exit $EXIT_CODE
