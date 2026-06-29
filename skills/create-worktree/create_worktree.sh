#!/usr/bin/env bash
# Create an isolated git worktree for feature development.
# Usage: create_worktree.sh <feature-name-kebab-case>
# Returns the worktree path on stdout (last line).

set -e

FEATURE_NAME="$1"

# Guard: a feature name is required.
if [ -z "$FEATURE_NAME" ]; then
    echo "Error: feature name (kebab-case) is required" >&2
    echo "Usage: $0 <feature-name>" >&2
    exit 1
fi

# Resolve this script's own directory so sibling helpers are called by a
# script-relative path (the hardcoded ~/.claude path does not exist when this
# script runs from a PR clone before merge).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the base/main worktree root explicitly. Do NOT trust pwd: the session
# may already be inside a linked worktree. The shared git dir lives at
# <base-root>/.git, so its parent is the main worktree root.
GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
BASE_ROOT=$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd)

# All feature worktrees live under <base-root>/_worktrees/<feature>.
WORKTREE_PATH="$BASE_ROOT/_worktrees/$FEATURE_NAME"

# Refresh refs from origin (prune deleted remote branches) so detection below
# sees the true remote state and new branches start off fresh origin/main.
git fetch --prune

# Ensure the parent directory for worktrees exists.
mkdir -p "$BASE_ROOT/_worktrees"

# Preflight: is this branch already checked out in another worktree? A branch
# can only be checked out in one worktree at a time, so report the existing
# path clearly instead of letting `git worktree add` fail opaquely.
EXISTING_CHECKOUT=$(git worktree list --porcelain \
    | awk -v b="refs/heads/$FEATURE_NAME" '
        /^worktree / { path = substr($0, 10) }
        $0 == "branch " b { print path }')
if [ -n "$EXISTING_CHECKOUT" ]; then
    echo "Error: branch '$FEATURE_NAME' is already checked out at: $EXISTING_CHECKOUT" >&2
    exit 1
fi

# Detect an existing REMOTE branch with an EXACT ref check (never a substring
# grep, which would treat 'feat' as existing when only 'feat-x' exists).
REMOTE_EXISTS=false
if git ls-remote --exit-code --heads origin "$FEATURE_NAME" >/dev/null 2>&1; then
    REMOTE_EXISTS=true
fi

# Preflight: does a LOCAL branch already exist? Worktrees share the repo's local
# refs, so new-branch mode (`git worktree add -b`) would fail if it exists.
LOCAL_EXISTS=false
if git show-ref --verify --quiet "refs/heads/$FEATURE_NAME"; then
    LOCAL_EXISTS=true
fi

if [ "$LOCAL_EXISTS" = true ]; then
    # A local branch already exists (and is not checked out elsewhere, per the
    # preflight above): reuse it directly in the new worktree.
    echo "Local branch detected: $FEATURE_NAME — checking it out in a new worktree."
    git worktree add "$WORKTREE_PATH" "$FEATURE_NAME"
elif [ "$REMOTE_EXISTS" = true ]; then
    # The branch exists on origin (and no local branch exists, per the preflight):
    # create a worktree with an explicit local tracking branch off
    # origin/$FEATURE_NAME (explicit --track instead of relying on git DWIM).
    echo "Existing remote branch detected: $FEATURE_NAME — checking it out in a new worktree."
    git worktree add --track -b "$FEATURE_NAME" "$WORKTREE_PATH" "origin/$FEATURE_NAME"
else
    # New-branch mode: branch off FRESH origin/main (never a stale local main),
    # then publish the branch and set its upstream. The push is non-fatal: under
    # set -e a push failure would otherwise abort before env setup and before the
    # final path is echoed, leaving a half-provisioned worktree.
    echo "New branch mode: creating $FEATURE_NAME off origin/main."
    git worktree add -b "$FEATURE_NAME" "$WORKTREE_PATH" origin/main
    git push -u origin "$FEATURE_NAME" || echo "Warning: push failed; branch is local-only, push manually later" >&2
fi

# Symlink env files from the base repo root into the new worktree.
bash "$SCRIPT_DIR/symlink_env_files.sh" "$BASE_ROOT" "$WORKTREE_PATH"

# Set up the project environment inside the new worktree.
cd "$WORKTREE_PATH"
bash "$SCRIPT_DIR/setup_project_env.sh"

# Final stdout line: the worktree path relative to the base root (consumed by the skill).
echo "_worktrees/$FEATURE_NAME"
