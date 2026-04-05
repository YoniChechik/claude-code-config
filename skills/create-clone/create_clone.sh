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
    echo "New branch mode: cloning main then creating $FEATURE_NAME."
    git clone -b main "$REPO_URL" "_clones/$FEATURE_NAME"
    cd "_clones/$FEATURE_NAME"
    git checkout -b "$FEATURE_NAME"
    git push -u origin "$FEATURE_NAME"
    cd "$ORIGINAL_REPO_DIR"
fi

# Symlink env files
bash ~/.claude/skills/create-clone/symlink_env_files.sh "$ORIGINAL_REPO_DIR" "_clones/$FEATURE_NAME"

# Setup environment inside clone
cd "_clones/$FEATURE_NAME"
bash ~/.claude/skills/create-clone/setup_project_env.sh
cd "$ORIGINAL_REPO_DIR"

echo "_clones/$FEATURE_NAME"
cd "_clones/$FEATURE_NAME"
