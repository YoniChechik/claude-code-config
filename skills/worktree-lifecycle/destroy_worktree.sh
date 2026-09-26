#!/usr/bin/env bash
# Fully tear down a git worktree: detach it from git's bookkeeping AND delete
# every byte on disk (node_modules, .venv, build output, everything) — not
# just the git-tracked files `git worktree remove` alone would touch.
# Usage: destroy_worktree.sh <name-or-path> [--force] [--delete-branch]
#   <name-or-path>   a bare feature name (matches .claude/worktrees/<name>)
#                     or a full path to a registered worktree.
#   --force          skip the uncommitted/unpushed safety check.
#   --delete-branch  also delete the local branch once the worktree is gone
#                     (default: keep it, so the history stays recoverable).

set -e

TARGET_ARG=""
FORCE=0
DELETE_BRANCH=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --delete-branch) DELETE_BRANCH=1 ;;
        -*)
            echo "Error: unknown flag $arg" >&2
            exit 1
            ;;
        *) TARGET_ARG="$arg" ;;
    esac
done

if [ -z "$TARGET_ARG" ]; then
    echo "Error: a worktree name or path is required" >&2
    echo "Usage: $0 <name-or-path> [--force] [--delete-branch]" >&2
    exit 1
fi

# --- Resolve the TRUE main repo root, regardless of cwd -----------------
# Same fix as setup_worktree.sh: --git-common-dir always points at the main
# repo's real .git, so this script works no matter where it's invoked from.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" || {
    echo "Error: not inside a git repository" >&2
    exit 1
}
GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" && pwd)"
MAIN_REPO_ROOT="$(dirname "$GIT_COMMON_DIR")"

# --- Locate the worktree via git's own bookkeeping -----------------------
# Emits one line per worktree as "<abs-path>\t<branch-or-empty>".
list_worktrees() {
    git -C "$MAIN_REPO_ROOT" worktree list --porcelain | awk '
        /^worktree / { if (wt != "") print wt "\t" br; wt = substr($0, 10); br = "" }
        /^branch /   { br = substr($0, 8); sub(/^refs\/heads\//, "", br) }
        END { if (wt != "") print wt "\t" br }
    '
}

if [ -e "$TARGET_ARG" ]; then
    CANDIDATE_PATH="$(cd "$TARGET_ARG" && pwd)"
else
    CANDIDATE_PATH="$MAIN_REPO_ROOT/.claude/worktrees/$TARGET_ARG"
fi

WT_PATH=""
BRANCH=""
while IFS=$'\t' read -r wt_path wt_branch; do
    if [ "$wt_path" = "$CANDIDATE_PATH" ]; then
        WT_PATH="$wt_path"
        BRANCH="$wt_branch"
        break
    fi
done < <(list_worktrees)

if [ -z "$WT_PATH" ]; then
    echo "Error: no registered worktree matches '$TARGET_ARG' (resolved to $CANDIDATE_PATH)." >&2
    echo "Registered worktrees:" >&2
    list_worktrees | awk -F'\t' '{print "  " $1 "  [" $2 "]"}' >&2
    exit 1
fi

if [ "$WT_PATH" = "$MAIN_REPO_ROOT" ]; then
    echo "Error: refusing to destroy the main repo checkout ($MAIN_REPO_ROOT)." >&2
    exit 1
fi

# --- Safety check: uncommitted or unpushed work is irreversible to lose ---
DIRTY_STATUS="$(git -C "$WT_PATH" status --porcelain 2>/dev/null || true)"
UPSTREAM="$(git -C "$WT_PATH" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
UNPUSHED_LOG=""
if [ -n "$UPSTREAM" ]; then
    UNPUSHED_LOG="$(git -C "$WT_PATH" log --oneline '@{u}..' 2>/dev/null || true)"
fi

if [ "$FORCE" -ne 1 ] && { [ -n "$DIRTY_STATUS" ] || [ -n "$UNPUSHED_LOG" ] || [ -z "$UPSTREAM" ]; }; then
    echo "Refusing to destroy $WT_PATH (branch: ${BRANCH:-detached}) without --force." >&2
    echo >&2
    if [ -n "$DIRTY_STATUS" ]; then
        echo "Uncommitted changes that would be LOST:" >&2
        echo "$DIRTY_STATUS" >&2
        echo >&2
    fi
    if [ -n "$UNPUSHED_LOG" ]; then
        echo "Unpushed commits on '$BRANCH' that would be LOST (ahead of $UPSTREAM):" >&2
        echo "$UNPUSHED_LOG" >&2
        echo >&2
    fi
    if [ -z "$UPSTREAM" ]; then
        echo "Branch '$BRANCH' has no upstream tracking branch — cannot confirm its commits exist anywhere else." >&2
        echo >&2
    fi
    echo "Re-run with --force to delete anyway. This cannot be undone for anything not committed and pushed." >&2
    exit 1
fi

# --- Teardown -------------------------------------------------------------
SIZE_BEFORE="$(du -sh "$WT_PATH" 2>/dev/null | cut -f1 || true)"

# `git worktree remove` detaches it from git's bookkeeping cleanly.
git -C "$MAIN_REPO_ROOT" worktree remove --force "$WT_PATH"

# Belt-and-suspenders: delete anything left on disk regardless — the whole
# point is getting rid of node_modules/.venv/build output, not just
# git-tracked files, and this also cleans up if the directory was untracked.
rm -rf "$WT_PATH"

# Clean up any stale administrative files left behind.
git -C "$MAIN_REPO_ROOT" worktree prune

BRANCH_DELETED="no"
if [ "$DELETE_BRANCH" -eq 1 ] && [ -n "$BRANCH" ]; then
    git -C "$MAIN_REPO_ROOT" branch -D "$BRANCH"
    BRANCH_DELETED="yes"
fi

echo "Removed worktree: $WT_PATH"
echo "Branch: ${BRANCH:-<detached>} (deleted: $BRANCH_DELETED)"
if [ -n "$SIZE_BEFORE" ]; then
    echo "Disk space freed: approximately $SIZE_BEFORE"
fi
