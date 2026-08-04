#!/usr/bin/env bash
# Create an isolated git worktree for feature development.
# Usage: create_worktree.sh <feature-name-kebab-case>
# Returns the worktree path (relative to the repo root) on stdout (last line).

set -e

FEATURE_NAME="$1"

if [ -z "$FEATURE_NAME" ]; then
    echo "Error: feature name (kebab-case) is required" >&2
    echo "Usage: $0 <feature-name>" >&2
    exit 1
fi

# Always anchor on the repo root, not the current directory: `git worktree add`
# with a relative path resolves against cwd, and worktrees must live at the
# canonical <repo-root>/.claude/worktrees/<name> location (Claude Code's native
# worktree convention, shared with the harness EnterWorktree tool).
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

WORKTREE_REL=".claude/worktrees/$FEATURE_NAME"
WORKTREE_ABS="$REPO_ROOT/$WORKTREE_REL"

# Refresh remote refs so branch detection and origin/main are both current.
git fetch --prune

# An existing worktree path is a hard error — bail out with a clear message
# instead of letting `git worktree add` fail cryptically.
if [ -e "$WORKTREE_ABS" ]; then
    echo "Error: $WORKTREE_REL already exists. Use /cd-permanent $WORKTREE_REL to work in it." >&2
    exit 1
fi

mkdir -p "$REPO_ROOT/.claude/worktrees"

# A branch can only be checked out in ONE worktree at a time, so the three cases
# below are distinguished by where the branch already lives (if anywhere).
if git show-ref --verify --quiet "refs/heads/$FEATURE_NAME"; then
    # Case 1: local branch exists. Refuse if another worktree already holds it —
    # git would reject the add anyway, but the message is much less obvious.
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
    # Case 2: only the remote branch exists — create the local branch from it,
    # tracking origin, inside the new worktree.
    echo "Existing remote branch detected: origin/$FEATURE_NAME — checking it out in a worktree."
    git worktree add --track -b "$FEATURE_NAME" "$WORKTREE_REL" "origin/$FEATURE_NAME"
else
    # Case 3: brand new branch. Branch off the freshly fetched origin/main so we
    # never start from a stale local main, then publish it upstream.
    echo "New branch mode: creating $FEATURE_NAME off origin/main."
    git worktree add -b "$FEATURE_NAME" "$WORKTREE_REL" origin/main
    git -C "$WORKTREE_ABS" push -u origin "$FEATURE_NAME"
fi

# Worktrees share the .git object store but NOT the working tree, so .env files
# and installed dependencies still have to be provisioned per worktree.
bash ~/.claude/skills/create-worktree/symlink_env_files.sh "$REPO_ROOT" "$WORKTREE_ABS"

# Setup environment inside the worktree (uv venv / npm install / pnpm install).
cd "$WORKTREE_ABS"
bash ~/.claude/skills/create-worktree/setup_project_env.sh
cd "$REPO_ROOT"

# Set the terminal tab title to the feature/branch name.
# /rename is interactive-only and cannot be automated, so the tab title is the
# achievable equivalent — it persists because CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
# stops Claude from overwriting it.
# Resolve the user's real TTY via _notify.sh's helper, since this script may run
# from a subagent where stdout is not the terminal. The escape sequence must go
# to the TTY, NEVER to stdout, because the final stdout line below (the worktree
# path) is consumed by the caller.
source ~/.claude/scripts/_notify.sh
TITLE_TTY=$(_resolve_target_tty)
# OSC 0 sets both icon+window title (respected by iTerm2 as the tab title),
# matching the sequence used in _notify.sh for consistency.
printf '\033]0;%s\007' "$FEATURE_NAME" > "$TITLE_TTY" 2>/dev/null || true

echo "$WORKTREE_REL"
