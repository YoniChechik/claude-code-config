#!/usr/bin/env bash
# Create an isolated git worktree for feature development, anchored on the
# TRUE main repo root regardless of the caller's current working directory.
# Usage: setup_worktree.sh <feature-name-kebab-case>
# Returns the worktree path (relative to the main repo root) on stdout (last line).

set -e

FEATURE_NAME="$1"

if [ -z "$FEATURE_NAME" ]; then
    echo "Error: feature name (kebab-case) is required" >&2
    echo "Usage: $0 <feature-name>" >&2
    exit 1
fi

case "$FEATURE_NAME" in
    */*|.*|*..*)
        echo "Error: feature name must be a flat kebab-case string (no slashes, no leading dot, no '..')" >&2
        exit 1
        ;;
esac

# --- Resolve the TRUE main repo root, regardless of cwd -----------------
# `git rev-parse --show-toplevel` is what the older create-worktree script
# used, and it is the root cause of the nesting bug: run from inside a
# LINKED worktree, it returns that worktree's own top level, not the main
# repo's. `--git-common-dir` instead always points at the main repo's real
# `.git` directory (shared by every linked worktree), so its parent is
# always the true main repo root no matter where this script is invoked from.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" || {
    echo "Error: not inside a git repository" >&2
    exit 1
}
# --git-common-dir can be relative to cwd; resolve it to an absolute path.
GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" && pwd)"
MAIN_REPO_ROOT="$(dirname "$GIT_COMMON_DIR")"

WORKTREE_REL=".claude/worktrees/$FEATURE_NAME"
WORKTREE_ABS="$MAIN_REPO_ROOT/$WORKTREE_REL"

# --- Belt-and-suspenders anti-nesting guard ------------------------------
# Even though --git-common-dir already resolves the real main repo root, a
# second, explicit check catches any case that reasoning slipped past: cross
# reference every ALREADY-registered worktree path against both the resolved
# main repo root and the intended target. A worktree nested inside another
# worktree is destroyed without warning by this repo's automated sweep hook,
# so this must hard-fail loudly rather than silently produce a bad path.
while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    [ "$wt_path" = "$MAIN_REPO_ROOT" ] && continue
    case "$MAIN_REPO_ROOT/" in
        "$wt_path"/*)
            echo "Error: resolved main repo root ($MAIN_REPO_ROOT) is itself nested inside worktree $wt_path." >&2
            echo "Refusing to create a worktree from here — run from the actual main repo checkout." >&2
            exit 1
            ;;
    esac
    case "$WORKTREE_ABS/" in
        "$wt_path"/*)
            echo "Error: target path $WORKTREE_ABS would be nested inside existing worktree $wt_path." >&2
            echo "Never create a worktree inside another worktree — this hard-fails on purpose. Run from the main repo checkout." >&2
            exit 1
            ;;
    esac
done < <(git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

cd "$MAIN_REPO_ROOT"

# Refresh remote refs so branch detection and origin/main are both current.
git fetch --prune

# An existing worktree path is a hard error — bail out with a clear message
# instead of letting `git worktree add` fail cryptically.
if [ -e "$WORKTREE_ABS" ]; then
    echo "Error: $WORKTREE_REL already exists. Run: cd \"$MAIN_REPO_ROOT/$WORKTREE_REL\"" >&2
    exit 1
fi

mkdir -p "$MAIN_REPO_ROOT/.claude/worktrees"

# A branch can only be checked out in ONE worktree at a time, so the three
# cases below are distinguished by where the branch already lives (if anywhere).
if git show-ref --verify --quiet "refs/heads/$FEATURE_NAME"; then
    # Case 1: local branch exists. Refuse if another worktree already holds it.
    existing_wt=$(git worktree list --porcelain \
        | awk -v b="refs/heads/$FEATURE_NAME" '
            /^worktree / { wt = substr($0, 10) }
            /^branch /   { if (substr($0, 8) == b) { print wt; exit } }')
    if [ -n "$existing_wt" ]; then
        echo "Error: branch $FEATURE_NAME is already checked out at $existing_wt" >&2
        exit 1
    fi
    echo "Existing local branch detected: $FEATURE_NAME — attaching a worktree to it."
    git worktree add "$WORKTREE_REL" "$FEATURE_NAME"
elif git show-ref --verify --quiet "refs/remotes/origin/$FEATURE_NAME"; then
    # Case 2: only the remote branch exists — create the local branch from it.
    echo "Existing remote branch detected: origin/$FEATURE_NAME — checking it out in a worktree."
    git worktree add --track -b "$FEATURE_NAME" "$WORKTREE_REL" "origin/$FEATURE_NAME"
else
    # Case 3: brand new branch. Branch off freshly fetched origin/main so we
    # never start from a stale local main, then publish it upstream.
    echo "New branch mode: creating $FEATURE_NAME off origin/main."
    git worktree add -b "$FEATURE_NAME" "$WORKTREE_REL" origin/main
    git -C "$WORKTREE_ABS" push -u origin "$FEATURE_NAME"
fi

# --- Symlink .env* files from the main checkout into the new worktree ----
# Worktrees share the .git object store but NOT the working tree, so .env
# files still have to be provisioned per worktree.
echo "Symlinking .env* files from $MAIN_REPO_ROOT to $WORKTREE_ABS:"
found_any=0
while IFS= read -r -d '' source_file; do
    found_any=1
    rel_path="${source_file#"$MAIN_REPO_ROOT"/}"
    target_file="$WORKTREE_ABS/$rel_path"
    mkdir -p "$(dirname "$target_file")"
    rm -f "$target_file"
    ln -s "$source_file" "$target_file"
    echo "  $rel_path -> $source_file"
done < <(find "$MAIN_REPO_ROOT" \
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
    echo "No .env* files found in $MAIN_REPO_ROOT"
fi

# --- Install dependencies inside the new worktree ------------------------
# This is the actual disk-space cost (node_modules across every workspace
# project) — the fix for that is the sibling destroy_worktree.sh teardown
# script, not skipping install here: the worktree needs this to be usable.
cd "$WORKTREE_ABS"
if [ -f "pyproject.toml" ]; then
    echo "Detected Python project (pyproject.toml found) — running: uv venv"
    uv venv
fi
if [ -f "pnpm-lock.yaml" ]; then
    echo "Detected pnpm project (pnpm-lock.yaml found) — running: pnpm install"
    pnpm install
elif [ -f "package-lock.json" ]; then
    echo "Detected npm project (package-lock.json found) — running: npm install"
    npm install
fi
cd "$MAIN_REPO_ROOT"

echo "$WORKTREE_REL"
