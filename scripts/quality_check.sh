#!/bin/bash
# Runs linting, formatting, and type checks on changed files
# Supports Python (ruff, ty) and JS/TS (eslint, prettier, tsc)
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
#   1. Local node_modules/.bin (versions pinned by the repo).
#   2. `npx --no-install` (use only what's already cached).
# ============================================================
JS_TOOLCHAIN="npx"
detect_js_toolchain() {
    # Prefer local node_modules/.bin if present — pins to the repo's versions.
    if [ -d "node_modules/.bin" ]; then
        JS_TOOLCHAIN="local"
        return
    fi

    JS_TOOLCHAIN="npx"
}
detect_js_toolchain

case "$JS_TOOLCHAIN" in
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

# Walk up from a file's directory to find the nearest ancestor that owns
# a `pyproject.toml`. That directory is the file's "project root".
#
# WHY THIS MATTERS: monorepos can contain multiple *isolated* uv projects,
# each with its own pyproject.toml + uv.lock + .venv (e.g. core/backend and
# core/bot here). A subproject's dependencies (stripe, google-cloud-logging,
# …) only resolve when `uv run` is executed from *inside* that subproject's
# directory — uv resolves the venv relative to the cwd. Running
# `uv run ty check backend/foo.py` from the repo root uses the *root* env
# (or none), so ty can't see the subproject's deps and emits spurious
# `unresolved-import` errors plus a cascade of bogus type errors. The fix is
# to group changed files by their owning project root and run ruff/ty from
# within each root, against paths made relative to that root.
find_project_root() {
    local dir
    dir=$(dirname "$1")
    while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
        if [ -f "$dir/pyproject.toml" ]; then
            printf '%s' "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
    # No owning pyproject.toml found anywhere up the tree — treat the repo
    # root (".") as the project so behavior matches the old single-env path.
    printf '.'
}

# Run a uv-backed command for every project root, with each root's files
# passed as paths relative to that root and the command run from inside it.
# Args: <label> <fail-on-error: true|false> <uv subcommand...>
# Reads the newline-separated "<root>\t<relpath>" pairs from $PY_FILES_BY_ROOT.
run_py_per_project() {
    local label="$1"; shift
    local fail_on_error="$1"; shift
    # Remaining args are the command, e.g. `run ruff check` or `run ty check`.
    local roots
    roots=$(printf '%s\n' "$PY_FILES_BY_ROOT" | cut -f1 | sort -u)
    local root
    while IFS= read -r root; do
        [ -z "$root" ] && continue
        local rel_files
        rel_files=$(printf '%s\n' "$PY_FILES_BY_ROOT" | awk -F'\t' -v r="$root" '$1==r{print $2}')
        [ -z "$rel_files" ] && continue
        echo "=== $label ($root) ==="
        # Run uv from inside the project root so it picks up that project's
        # isolated venv. Paths are already relative to $root.
        if ! ( cd "$root" && printf '%s\n' "$rel_files" | xargs uv "$@" ); then
            if [ "$fail_on_error" = "true" ]; then
                EXIT_CODE=1
            fi
        fi
    done <<< "$roots"
}

PY_FILES=$(get_changed_files "*.py")

if [ -n "$PY_FILES" ]; then
    echo "=== Python files to check ==="
    echo "$PY_FILES"
    echo ""

    # Build a "<project-root>\t<path-relative-to-root>" table so each isolated
    # uv project's files are checked from within that project's directory.
    PY_FILES_BY_ROOT=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        root=$(find_project_root "$f")
        if [ "$root" = "." ]; then
            rel="$f"
        else
            rel="${f#"$root"/}"
        fi
        PY_FILES_BY_ROOT+="${root}"$'\t'"${rel}"$'\n'
    done <<< "$PY_FILES"

    if $FIX_MODE; then
        if check_tool "ruff" "uv"; then
            run_py_per_project "Running ruff format" false run ruff format
            run_py_per_project "Running ruff check --fix" false run ruff check --fix --unsafe-fixes
        fi
    fi

    if check_tool "ruff" "uv"; then
        run_py_per_project "Running ruff check" true run ruff check
    fi

    if check_tool "ty" "uv"; then
        run_py_per_project "Running ty check" true run ty check
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

    # Use local node_modules first, fall back to npx --no-install.
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
else
    echo "No JS/TS files changed"
fi

echo ""

# ============================================================
# Markdown
# ------------------------------------------------------------
# CI runs Prettier against changed Markdown in two places that this
# script previously never touched:
#   - Quality CI      -> job `format`             (npx prettier --check on
#     changed *.md / */CLAUDE.md files)
#   - infra-github-ci -> job `infra-github-lint`  (prettier --check .)
# Neither gate is scoped to Python/JS files, so a docs-only change sailed
# through this script and only failed once it hit CI. Mirror the same file
# selection and tool here so Markdown is checked locally too.
#
# This script is user-global and runs in every repo, many of which have no
# Prettier setup (or no npx/node at all). Only run the check when BOTH a
# resolvable prettier binary AND a repo-level Prettier config are present --
# otherwise skip quietly instead of hard-failing an unrelated repo's run.
#
# NOTE: this leg is check-only, even under --fix. `prettier --write` on
# Markdown corrupts pre-existing prose here (it turns `+` continuation lines
# into list bullets, and misreads a line starting "2026)" as an ordered-list
# marker and reflows it wrong) -- a real incident this script caused. So we
# never write to Markdown; violations are reported and must be fixed by hand.
# ============================================================

MD_FILES=$(get_changed_files "*.md" "*/CLAUDE.md")

if [ -n "$MD_FILES" ]; then
    echo "=== Markdown files to check ==="
    echo "$MD_FILES"
    echo ""

    # A repo-level Prettier config can live in a dotfile, a *.config.js, or
    # an embedded "prettier" key in package.json. Check all three forms
    # before assuming the repo actually opts into Prettier.
    HAS_PRETTIER_CONFIG=false
    for cfg in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
        .prettierrc.js .prettierrc.cjs .prettierrc.mjs \
        prettier.config.js prettier.config.cjs prettier.config.mjs; do
        if [ -f "$cfg" ]; then
            HAS_PRETTIER_CONFIG=true
            break
        fi
    done
    if [ "$HAS_PRETTIER_CONFIG" = false ] && grep -q '"prettier"[[:space:]]*:' package.json 2>/dev/null; then
        HAS_PRETTIER_CONFIG=true
    fi

    if [ "$HAS_PRETTIER_CONFIG" = false ]; then
        echo "SKIP: no Prettier config found in repo root, skipping Markdown format check"
    elif [ ! -x "node_modules/.bin/prettier" ] && ! command -v npx &>/dev/null; then
        echo "SKIP: npx/prettier not found, skipping Markdown format check"
    else
        PRETTIER_CMD=$(resolve_js_tool prettier)

        # No --write branch here on purpose (see NOTE above): Markdown is
        # always check-only, in both plain and --fix mode.
        echo "=== Running prettier --check (Markdown) ==="
        # shellcheck disable=SC2086
        if ! echo "$MD_FILES" | xargs $PRETTIER_CMD --check; then
            EXIT_CODE=1
            if $FIX_MODE; then
                echo ""
                echo "Markdown auto-fix is OFF on purpose: prettier --write corrupts prose in"
                echo "this repo (e.g. '+' continuation lines become list bullets; a line"
                echo "starting with a number+paren like '2026)' gets misparsed as an ordered"
                echo "list and reflowed wrong). Fix the file(s) listed above by hand, then"
                echo "verify each with:"
                echo "  npx prettier --check <file>"
            fi
        fi
    fi
else
    echo "No Markdown files changed"
fi

exit $EXIT_CODE
