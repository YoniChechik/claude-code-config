#!/bin/bash
# Cleanup clones and local branches whose remote tracking branches have been deleted

# Check if we're in a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: Not in a git repository!" >&2
    echo "This hook must be run from within a git repository." >&2
    echo "" >&2
    exit 2  # Blocking error
fi

# Get the root directory of the git repository
git_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$git_root" ]; then
    echo "ERROR: Failed to determine git repository root" >&2
    echo "" >&2
    exit 2
fi

echo "INFO: Starting cleanup for repository at $git_root" >&2

# Fetch remote updates and prune deleted remote branches
echo "INFO: Fetching remote updates and pruning deleted branches..." >&2
if ! git fetch -p 2>/dev/null; then
    echo "WARNING: Failed to fetch and prune remote branches" >&2
    echo "Continuing with cleanup anyway..." >&2
    echo "" >&2
fi

# Remove clones whose remote branches have been deleted
clones_removed=0
if [[ -d "${git_root}/_clones" ]]; then
    echo "INFO: Checking for clones with deleted remote branches..." >&2
    for clone_dir in "${git_root}/_clones"/*; do
        # Skip if not a directory
        [[ ! -d "$clone_dir" ]] && continue

        # Get the branch for this clone
        branch=$(git -C "$clone_dir" branch --show-current 2>/dev/null)

        # Skip main/master branches
        [[ $branch == "main" || $branch == "master" ]] && continue

        # Check if remote tracking branch is gone
        git branch -vv | grep "^..${branch}" | grep -q ': gone]'
        [[ $? -ne 0 ]] && continue

        # Remove clone whose remote was deleted
        echo "INFO: Removing clone for branch '$branch' (remote deleted): $clone_dir" >&2
        if rm -rf "$clone_dir" 2>/dev/null; then
            ((clones_removed++))
        else
            echo "WARNING: Failed to remove clone directory: $clone_dir" >&2
        fi
    done

    if [ $clones_removed -eq 0 ]; then
        echo "INFO: No clones to remove" >&2
    else
        echo "INFO: Removed $clones_removed clone(s)" >&2
    fi
else
    echo "INFO: No _clones directory found at ${git_root}/_clones" >&2
fi

# Remove local branches whose remote tracking branches have been deleted
branches_removed=0
echo "INFO: Checking for local branches with deleted remote tracking branches..." >&2
git branch -vv | while read -r line; do
    # Skip current branch (marked with *)
    [[ $line == \** ]] && continue

    # Extract branch name
    branch=$(echo "$line" | awk '{print $1}')

    # Skip main/master branches
    [[ $branch == "main" || $branch == "master" ]] && continue

    # Only delete if remote tracking shows "gone"
    echo "$line" | grep -q ': gone]' || continue

    # Delete branch whose remote was deleted
    echo "INFO: Deleting local branch '$branch' (remote deleted)" >&2
    if git branch -D "$branch" 2>/dev/null; then
        ((branches_removed++))
    else
        echo "WARNING: Failed to delete branch: $branch" >&2
    fi
done

if [ $branches_removed -eq 0 ]; then
    echo "INFO: No local branches to remove" >&2
else
    echo "INFO: Removed $branches_removed local branch(es)" >&2
fi

echo "INFO: Cleanup complete" >&2
echo "" >&2
exit 0
