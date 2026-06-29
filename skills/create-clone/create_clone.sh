#!/usr/bin/env bash
# Create an isolated git clone for feature development.
# Usage: create_clone.sh <feature-name-kebab-case>
# Returns the clone path on stdout (last line).

set -e

FEATURE_NAME="$1"

if [ -z "$FEATURE_NAME" ]; then
    echo "Error: feature name (kebab-case) is required" >&2
    echo "Usage: $0 <feature-name>" >&2
    exit 1
fi

ORIGINAL_REPO_DIR=$(pwd)
REPO_URL=$(git config --get remote.origin.url)

# Check for existing remote branch
git fetch --prune
EXISTING=$(git branch -r | grep "origin/$FEATURE_NAME" || true)

mkdir -p _clones

if [ -n "$EXISTING" ]; then
    echo "Existing branch detected: $FEATURE_NAME — cloning it."
    git clone -b "$FEATURE_NAME" "$REPO_URL" "_clones/$FEATURE_NAME"
else
    echo "New branch mode: fetching latest main from origin, then creating $FEATURE_NAME off origin/main."
    # Clone from origin URL (always a fresh network fetch), then explicitly
    # fetch origin and branch off origin/main to guarantee we start from the
    # latest upstream main — never a stale local main.
    git clone "$REPO_URL" "_clones/$FEATURE_NAME"
    cd "_clones/$FEATURE_NAME"
    git fetch origin main
    git checkout -b "$FEATURE_NAME" origin/main
    git push -u origin "$FEATURE_NAME"
    cd "$ORIGINAL_REPO_DIR"
fi

# Symlink env files
bash ~/.claude/skills/create-clone/symlink_env_files.sh "$ORIGINAL_REPO_DIR" "_clones/$FEATURE_NAME"

# Setup environment inside clone
cd "_clones/$FEATURE_NAME"
bash ~/.claude/skills/create-clone/setup_project_env.sh
cd "$ORIGINAL_REPO_DIR"

# Set the terminal tab title to the feature/branch name.
# /rename is interactive-only and cannot be automated, so the tab title is the
# achievable equivalent — it persists because CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
# stops Claude from overwriting it.
# Resolve the user's real TTY by walking the PPID chain (mirrors _notify.sh's
# find_user_tty), since this script may run from a subagent where stdout is not
# the terminal. The escape sequence must go to the TTY, NEVER to stdout, because
# the final stdout line below (the clone path) is consumed by the caller.
source ~/.claude/scripts/_notify.sh
TITLE_TTY=$(find_user_tty)
if [ -z "$TITLE_TTY" ] || [ ! -w "$TITLE_TTY" ]; then
    TITLE_TTY=/dev/tty
fi
# OSC 0 sets both icon+window title (respected by iTerm2 as the tab title),
# matching the sequence used in _notify.sh for consistency.
printf '\033]0;%s\007' "$FEATURE_NAME" > "$TITLE_TTY" 2>/dev/null || true

echo "_clones/$FEATURE_NAME"
