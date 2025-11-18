#!/bin/bash
# Cleanup clones and local branches whose remote tracking branches have been deleted

# Get the root directory of the git repository
git_root=$(git rev-parse --show-toplevel)

# Fetch remote updates and prune deleted remote branches
git fetch -p

# Remove clones whose remote branches have been deleted
if [[ -d "${git_root}/_clones" ]]; then
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
        echo "Removing clone for $branch (remote deleted): $clone_dir"
        rm -rf "$clone_dir" 2>/dev/null
    done
fi

# Remove local branches whose remote tracking branches have been deleted
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
    echo "Deleting branch $branch (remote deleted)"
    git branch -D "$branch" 2>/dev/null
done
