#!/bin/bash
# Runs linting, formatting, and type checks on changed files
# Supports Python (ruff, ty) and JS/TS (eslint, prettier, tsc, or vp toolchain)
# Usage: ./quality_check.sh [--fix]

set -euo pipefail

FIX_MODE=false
if [ "${1:-}" = "--fix" ]; then
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

# ------------------------------------------------------------
# Detect the repo's base branch dynamically.
# Hardcoding `main` breaks on repos that use `master`, `develop`,
# or have renamed their default branch. We ask git for the
# remote's actual default first (canonical source of truth),
# then fall back to common names, then to a single-commit fallback.
# ------------------------------------------------------------
detect_base_ref() {
    local base=""
    # 1) Authoritative: remote HEAD points at the default branch.
    if base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
        base="${base#refs/remotes/origin/}"
    fi

    # 2) Fallbacks if origin/HEAD isn't set (e.g. fresh clone, no remote).
    if [ -z "$base" ]; then
        if git show-ref --verify --quiet refs/heads/main; then
            base="main"
        elif git show-ref --verify --quiet refs/heads/master; then
            base="master"
        else
            # 3) Single-commit fallback. Won't crash if HEAD~1 is missing.
            echo "HEAD~1"
            return
        fi
    fi

    # Prefer origin/<base> when present — it reflects the actual integration
    # point, not a stale local copy.
    if git show-ref --verify --quiet "refs/remotes/origin/$base"; then
        echo "origin/$base"
    else
        echo "$base"
    fi
}

BASE_REF=$(detect_base_ref)
echo "Base ref for diff: $BASE_REF"

get_changed_files() {
    # Each argument is a single glob pattern (e.g. "*.ts" "*.tsx").
    # IMPORTANT: git pathspecs are expanded by git itself, NOT by the shell.
    # We must pass each glob as one literal argument to git — if the shell
    # word-splits or glob-expands them first, git sees literal filenames
    # that don't exist and silently returns nothing. We disable shell
    # globbing locally via `set -f`, then pass the patterns as `"$@"` so
    # each is one argv entry to git.
    local patterns=("$@")

    set -f

    # Branch-relative changes intersected with tracked files. Misses files
    # that exist only in the index (staged-but-not-committed-on-branch).
    local branch_files=""
    branch_files=$(comm -12 \
        <(git diff --name-only "$BASE_REF"...HEAD -- "${patterns[@]}" 2>/dev/null | sort) \
        <(git ls-files -- "${patterns[@]}" 2>/dev/null | sort) 2>/dev/null || true)

    # Working-tree-vs-index (unstaged) changes.
    local uncommitted=""
    uncommitted=$(git diff --name-only -- "${patterns[@]}" 2>/dev/null || true)

    # Index-vs-HEAD (staged-only) changes — without this, `git add`ed files
    # that the user hasn't committed yet get silently skipped.
    local staged=""
    staged=$(git diff --cached --name-only -- "${patterns[@]}" 2>/dev/null || true)

    local untracked=""
    untracked=$(git ls-files --others --exclude-standard -- "${patterns[@]}" 2>/dev/null || true)

    set +f

    # Union all four sources, dedup, drop blanks.
    printf '%s\n%s\n%s\n%s\n' "$branch_files" "$uncommitted" "$staged" "$untracked" \
        | sort -u | grep -v '^$' || true
}

# ============================================================
# Toolchain detection (JS/TS)
# ------------------------------------------------------------
# Default: npx, which auto-installs the *latest* major of any
# tool not present locally — this can mismatch the repo's config
# (e.g. eslint 10 against an eslint-8 config) and produce
# confusing failures. We prefer, in order:
#   1. `vp` (Vite+ unified toolchain) if the repo opts into it.
#   2. Local node_modules/.bin (versions pinned by the repo).
#   3. `npx --no-install` (use only what's already cached).
# ============================================================
JS_TOOLCHAIN="npx"
detect_js_toolchain() {
    # vp signal: pnpm-workspace.yaml + `vp` on PATH, OR vite-plus in package.json deps.
    local has_vp_bin=false
    if command -v vp &>/dev/null; then
        has_vp_bin=true
    fi

    if $has_vp_bin && [ -f "pnpm-workspace.yaml" ]; then
        JS_TOOLCHAIN="vp"
        return
    fi
    if $has_vp_bin && [ -f "package.json" ] && grep -q '"vite-plus"' package.json 2>/dev/null; then
        JS_TOOLCHAIN="vp"
        return
    fi

    # Prefer local node_modules/.bin if present — pins to the repo's versions.
    if [ -d "node_modules/.bin" ]; then
        JS_TOOLCHAIN="local"
        return
    fi

    JS_TOOLCHAIN="npx"
}
detect_js_toolchain

case "$JS_TOOLCHAIN" in
    vp)    echo "Using vp toolchain" ;;
    local) echo "Using local node_modules/.bin" ;;
    npx)   echo "Using npx (no local install detected)" ;;
esac

# Resolve a JS tool to an absolute command (array form for xargs friendliness).
# Prefers local node_modules/.bin (repo-pinned), then `npx --no-install` so
# npx can't auto-fetch a newer major behind our back.
resolve_js_tool() {
    local tool="$1"
    if [ -x "node_modules/.bin/$tool" ]; then
        printf 'node_modules/.bin/%s' "$tool"
    else
        printf 'npx --no-install %s' "$tool"
    fi
}

# ============================================================
# Python
# ============================================================

PY_FILES=$(get_changed_files "*.py")

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

JS_FILES=$(get_changed_files "*.ts" "*.tsx" "*.js" "*.jsx")

if [ -n "$JS_FILES" ]; then
    echo "=== JS/TS files to check ==="
    echo "$JS_FILES"
    echo ""

    if [ "$JS_TOOLCHAIN" = "vp" ]; then
        # vp wraps fmt + lint + typecheck. `vp check` accepts file paths and
        # runs the repo-pinned tools — no risk of pulling a newer major.
        if $FIX_MODE; then
            echo "=== Running vp check --fix ==="
            # shellcheck disable=SC2086
            if ! echo "$JS_FILES" | xargs vp check --fix; then
                EXIT_CODE=1
            fi
        else
            echo "=== Running vp check ==="
            # shellcheck disable=SC2086
            if ! echo "$JS_FILES" | xargs vp check; then
                EXIT_CODE=1
            fi
        fi
    else
        # Non-vp path: use local node_modules first, fall back to npx --no-install.
        # Word-splitting on the resolved command is intentional — it's either
        # one path or `npx --no-install <tool>`, both safe to split.
        PRETTIER_CMD=$(resolve_js_tool prettier)
        ESLINT_CMD=$(resolve_js_tool eslint)
        TSC_CMD=$(resolve_js_tool tsc)

        if $FIX_MODE; then
            echo "=== Running prettier --write ==="
            # shellcheck disable=SC2086
            echo "$JS_FILES" | xargs $PRETTIER_CMD --write || true

            echo "=== Running eslint --fix ==="
            # shellcheck disable=SC2086
            echo "$JS_FILES" | xargs $ESLINT_CMD --fix || true
        fi

        echo "=== Running eslint ==="
        # shellcheck disable=SC2086
        if ! echo "$JS_FILES" | xargs $ESLINT_CMD; then
            EXIT_CODE=1
        fi

        if [ -f "tsconfig.json" ]; then
            echo "=== Running tsc --noEmit ==="
            # shellcheck disable=SC2086
            if ! $TSC_CMD --noEmit; then
                EXIT_CODE=1
            fi
        fi
    fi
else
    echo "No JS/TS files changed"
fi

exit $EXIT_CODE
