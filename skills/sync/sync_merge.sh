#!/usr/bin/env bash
# Fetch from origin and merge origin/main into the current branch if needed.
# Outputs a JSON object with merge status on stdout.
# Exit 0 = success (no merge needed, or clean merge).
# Exit 1 = merge conflicts detected (caller must resolve).

set -euo pipefail

# --- Step 1: Fetch latest state from origin ---
git fetch origin

# --- Step 2: Get branch state JSON from helper script ---
# git_branch_state.sh returns JSON like:
#   {"branch": "feat-x", "diverged": false, "behind_main": 3}
branch_state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")

# --- Step 3: Parse the relevant fields with jq ---
behind_main=$(echo "$branch_state" | jq -r '.behind_main')
diverged=$(echo "$branch_state" | jq -r '.diverged')

# --- Step 4: Decide if a merge is needed ---
# No merge needed when we are NOT behind main AND the branch has NOT diverged.
if [ "$behind_main" -eq 0 ] && [ "$diverged" = "false" ]; then
    echo '{"merged": false, "conflicts": false}'
    exit 0
fi

# --- Step 5: Attempt the merge ---
# Temporarily disable set -e so a merge conflict doesn't kill the script.
set +e
git merge origin/main --no-edit
merge_exit_code=$?
set -e

# --- Step 6: Report the result ---
if [ "$merge_exit_code" -eq 0 ]; then
    # Clean merge — all origin/main changes applied without conflicts.
    echo '{"merged": true, "conflicts": false}'
    exit 0
else
    # Merge conflicts detected — caller is responsible for resolving them.
    echo '{"merged": true, "conflicts": true}'
    exit 1
fi
