#!/bin/bash

# Helper function to print to both stdout and stderr for visibility
print_both() {
    echo "$1"
    echo "$1" >&2
}

# Get the .claude directory path
CLAUDE_DIR="$HOME/.claude"

# Check if .claude directory exists and is a git repository
if [ ! -d "$CLAUDE_DIR" ]; then
    print_both ""
    print_both "╔════════════════════════════════════════════════════════════════╗"
    print_both "║  ❌ ERROR: Claude config directory does not exist            ║"
    print_both "╠════════════════════════════════════════════════════════════════╣"
    print_both "║  Location: $CLAUDE_DIR"
    print_both "║  Expected a git repository with Claude configuration.         ║"
    print_both "╚════════════════════════════════════════════════════════════════╝"
    print_both ""
    exit 2  # Blocking error
fi

cd "$CLAUDE_DIR" || {
    print_both ""
    print_both "╔════════════════════════════════════════════════════════════════╗"
    print_both "║  ❌ ERROR: Cannot access Claude config directory             ║"
    print_both "╠════════════════════════════════════════════════════════════════╣"
    print_both "║  Location: $CLAUDE_DIR"
    print_both "╚════════════════════════════════════════════════════════════════╝"
    print_both ""
    exit 2
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    print_both ""
    print_both "╔════════════════════════════════════════════════════════════════╗"
    print_both "║  ❌ ERROR: Not a git repository                               ║"
    print_both "╠════════════════════════════════════════════════════════════════╣"
    print_both "║  Location: $CLAUDE_DIR"
    print_both "║  Initialize with: cd ~/.claude && git init                     ║"
    print_both "╚════════════════════════════════════════════════════════════════╝"
    print_both ""
    exit 2  # Blocking error
fi

# Fetch origin/main
if ! git fetch origin main >/dev/null 2>&1; then
    print_both ""
    print_both "╔════════════════════════════════════════════════════════════════╗"
    print_both "║  ⚠️  WARNING: Failed to fetch origin/main                     ║"
    print_both "╠════════════════════════════════════════════════════════════════╣"
    print_both "║  Check your network connection and git remote configuration.   ║"
    print_both "╚════════════════════════════════════════════════════════════════╝"
    print_both ""
    exit 2  # Blocking error
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

# Check if we're on a branch (not detached HEAD)
if [ -z "$CURRENT_BRANCH" ]; then
    print_both ""
    print_both "╔════════════════════════════════════════════════════════════════╗"
    print_both "║  ❌ ERROR: Detached HEAD state                                ║"
    print_both "╠════════════════════════════════════════════════════════════════╣"
    print_both "║  You must be on a branch.                                      ║"
    print_both "║  Switch with: cd ~/.claude && git checkout main                ║"
    print_both "╚════════════════════════════════════════════════════════════════╝"
    print_both ""
    exit 2  # Blocking error
fi

# Check if we are strictly >= origin/main (equal or ahead)
# First check: HEAD must be ancestor of or equal to origin/main (we're not behind)
# Second check: origin/main must be ancestor of HEAD (we're ahead or equal, not diverged)

if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    # origin/main is not an ancestor of HEAD - we're either behind or diverged

    if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        # HEAD is ancestor of origin/main - we're behind
        BEHIND_COUNT=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")
        print_both ""
        print_both "╔════════════════════════════════════════════════════════════════╗"
        print_both "║  ⚠️  WARNING: ~/.claude is BEHIND origin/main                 ║"
        print_both "╠════════════════════════════════════════════════════════════════╣"
        print_both "║  Branch: $CURRENT_BRANCH"
        print_both "║  Behind by: $BEHIND_COUNT commit(s)"
        print_both "║                                                                ║"
        print_both "║  Run: cd ~/.claude && git pull                                 ║"
        print_both "╚════════════════════════════════════════════════════════════════╝"
        print_both ""
    else
        # Neither is ancestor of the other - we've diverged
        print_both ""
        print_both "╔════════════════════════════════════════════════════════════════╗"
        print_both "║  ⚠️  WARNING: ~/.claude has DIVERGED from origin/main         ║"
        print_both "╠════════════════════════════════════════════════════════════════╣"
        print_both "║  Branch: $CURRENT_BRANCH"
        print_both "║  Both local and remote have different commits.                 ║"
        print_both "║                                                                ║"
        print_both "║  Run: cd ~/.claude && git pull                                 ║"
        print_both "╚════════════════════════════════════════════════════════════════╝"
        print_both ""
    fi

    exit 2  # Exit code 2 = blocking error, will show stderr to Claude
fi

# We're equal to or ahead of origin/main - all good
if git diff --quiet HEAD origin/main 2>/dev/null; then
    echo "INFO: Claude config repository is up to date with origin/main" >&2
else
    AHEAD_COUNT=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "unknown")
    echo "INFO: Claude config repository is ahead of origin/main by $AHEAD_COUNT commit(s)" >&2
fi

exit 0
