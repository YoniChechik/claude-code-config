#!/bin/bash
# Cleanup worktrees and local branches whose remote tracking branches have been deleted

# Get the root directory of the git repository
git_root=$(git rev-parse --show-toplevel)

# Fetch remote updates and prune deleted remote branches
git fetch -p

# Remove worktrees whose remote branches have been deleted
git worktree list --porcelain | while read -r line; do
    # Only process worktree lines
    [[ $line != worktree* ]] && continue

    # Extract worktree path
    worktree_path=${line#worktree }

    # Skip main repository directory
    [[ $worktree_path == "$git_root" ]] && continue

    # Get the branch for this worktree
    branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null)

    # Skip main/master branches
    [[ $branch == "main" || $branch == "master" ]] && continue

    # Check if remote tracking branch is gone
    git branch -vv | grep "^..${branch}" | grep -q ': gone]'
    [[ $? -ne 0 ]] && continue

    # Remove worktree whose remote was deleted
    echo "Removing worktree for $branch (remote deleted): $worktree_path"
    git worktree remove --force "$worktree_path" 2>/dev/null
done

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
