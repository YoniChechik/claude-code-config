#!/usr/bin/env bash
# Commit all staged changes and push to remote, then verify branch state.
# Usage: sync_commit_push.sh "<commit message>"
# Outputs JSON describing the result.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Step 1: Validate that a commit message was provided
# ──────────────────────────────────────────────────────────────
if [ -z "${1:-}" ]; then
    echo "Error: commit message is required" >&2
    echo "Usage: $0 \"<commit message>\"" >&2
    exit 1
fi

COMMIT_MSG="$1"

# ──────────────────────────────────────────────────────────────
# Step 2: Stage all changes (tracked + untracked)
# ──────────────────────────────────────────────────────────────
# Using -A to pick up new files, modifications, and deletions.
git add -A

# ──────────────────────────────────────────────────────────────
# Step 3: Check if there is actually anything to commit
# ──────────────────────────────────────────────────────────────
# `git diff --cached --quiet` exits 0 when there are NO staged changes,
# and exits 1 when there ARE staged changes.
if git diff --cached --quiet; then
    # Nothing staged — nothing to do. Report and exit cleanly.
    echo '{"committed": false, "pushed": false, "reason": "no_changes"}'
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# Step 4: Commit with the provided message
# ──────────────────────────────────────────────────────────────
git commit -m "$COMMIT_MSG"

# ──────────────────────────────────────────────────────────────
# Step 5: Push to remote
# ──────────────────────────────────────────────────────────────
# First attempt: plain push (works when upstream is already set).
# If that fails (e.g., no upstream tracking branch), fall back to
# setting the upstream with -u origin HEAD.
# We temporarily disable errexit so we can handle the failure manually.
set +e
git push 2>/dev/null
PUSH_EXIT=$?
set -e

if [ "$PUSH_EXIT" -ne 0 ]; then
    # Upstream not set — push and set tracking in one shot.
    git push -u origin HEAD
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Run git_branch_state.sh to get verification JSON
# ──────────────────────────────────────────────────────────────
# The script outputs JSON with keys: branch, diverged, behind_main.
BRANCH_STATE=$(bash "$HOME/.claude/scripts/git_branch_state.sh")

# ──────────────────────────────────────────────────────────────
# Step 7: Parse verification JSON and determine success
# ──────────────────────────────────────────────────────────────
# We consider the state "verified" when:
#   - behind_main == 0  (branch is up to date with main)
#   - diverged == false  (local and remote are in sync)
BEHIND_MAIN=$(echo "$BRANCH_STATE" | jq -r '.behind_main')
DIVERGED=$(echo "$BRANCH_STATE" | jq -r '.diverged')

VERIFIED=false
if [ "$BEHIND_MAIN" -eq 0 ] && [ "$DIVERGED" = "false" ]; then
    VERIFIED=true
fi

# ──────────────────────────────────────────────────────────────
# Step 8: Output final result JSON
# ──────────────────────────────────────────────────────────────
jq -n \
    --argjson committed true \
    --argjson pushed true \
    --argjson verified "$VERIFIED" \
    --argjson branch_state "$BRANCH_STATE" \
    '{committed: $committed, pushed: $pushed, verified: $verified, branch_state: $branch_state}'

# ──────────────────────────────────────────────────────────────
# Step 9: Exit with appropriate code
# ──────────────────────────────────────────────────────────────
# Exit 0 if verified, exit 1 if verification failed.
if [ "$VERIFIED" = "true" ]; then
    exit 0
else
    exit 1
fi
