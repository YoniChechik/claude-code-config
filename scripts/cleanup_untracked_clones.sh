#!/bin/bash
# Cleanup clones and local branches whose remote tracking branches have been deleted.
# Outputs a JSON systemMessage summarizing what happened.

# Not in a git repo — exit silently
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

git_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$git_root" ]; then
    exit 0
fi

# Fetch remote updates and prune deleted remote branches
git fetch -p 2>/dev/null

clones_dir="${git_root}/_clones"

# Track results
removed_clones=()
removed_clone_reasons=()
existing_clones=()
removed_branches=()

# --- Clone cleanup ---
if [[ -d "$clones_dir" ]]; then
    for clone_dir in "${clones_dir}"/*; do
        [[ ! -d "$clone_dir" ]] && continue
        [[ ! -d "$clone_dir/.git" ]] && continue

        branch=$(git -C "$clone_dir" branch --show-current 2>/dev/null)
        [[ -z "$branch" ]] && continue

        dir_name=$(basename "$clone_dir")

        if [[ $branch == "main" || $branch == "master" ]]; then
            existing_clones+=("$dir_name (branch: $branch)")
            continue
        fi

        if git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "refs/heads/$branch"; then
            existing_clones+=("$dir_name (branch: $branch)")
            continue
        fi

        # Remote branch is gone — remove the clone
        if rm -rf "$clone_dir" 2>/dev/null; then
            removed_clones+=("$dir_name")
            removed_clone_reasons+=("remote branch '$branch' deleted")
        fi
    done
fi

# --- Local branch cleanup ---
while read -r line; do
    [[ $line == \** ]] && continue

    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue

    echo "$line" | grep -q ': gone]' || continue

    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

# --- Build systemMessage ---
has_existing=${#existing_clones[@]}
has_removed_clones=${#removed_clones[@]}
has_removed_branches=${#removed_branches[@]}

# Nothing interesting — exit silently
if [[ $has_existing -eq 0 && $has_removed_clones -eq 0 && $has_removed_branches -eq 0 ]]; then
    exit 0
fi

msg="Git cleanup results for ${git_root}:"

if [[ $has_existing -gt 0 ]]; then
    msg+="\n\nExisting clones in _clones/:"
    for c in "${existing_clones[@]}"; do
        msg+="\n- $c"
    done
fi

if [[ $has_removed_clones -gt 0 ]]; then
    msg+="\n\nRemoved clones:"
    for i in "${!removed_clones[@]}"; do
        msg+="\n- ${removed_clones[$i]} (${removed_clone_reasons[$i]})"
    done
fi

if [[ $has_removed_branches -gt 0 ]]; then
    msg+="\n\nRemoved local branches (remote gone):"
    for b in "${removed_branches[@]}"; do
        msg+="\n- $b"
    done
fi

jq -n --arg msg "$msg" '{"systemMessage": $msg}'
exit 0
