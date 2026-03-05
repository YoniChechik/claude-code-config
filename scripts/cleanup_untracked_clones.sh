#!/bin/bash
# Cleanup clones and local branches whose remote tracking branches have been deleted.

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

git_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ $? -ne 0 ]] || [[ -z "$git_root" ]]; then
    exit 0
fi

git fetch -p 2>/dev/null

clones_dir="${git_root}/_clones"

removed_clones=()
existing_clones=()
removed_branches=()

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

        if rm -rf "$clone_dir" 2>/dev/null; then
            removed_clones+=("$dir_name (remote deleted)")
        fi
    done
fi

while read -r line; do
    [[ $line == \** ]] && continue

    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue

    echo "$line" | grep -q ': gone]' || continue

    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

has_existing=${#existing_clones[@]}
has_removed_clones=${#removed_clones[@]}
has_removed_branches=${#removed_branches[@]}

if [[ $has_existing -eq 0 && $has_removed_clones -eq 0 && $has_removed_branches -eq 0 ]]; then
    exit 0
fi

CYAN='\033[36m'
BOLD_CYAN='\033[1;36m'
RESET='\033[0m'
SEP="════════════════════════════════════════"

_print_output() {
    printf "${CYAN}${SEP}${RESET}\n"
    printf "${BOLD_CYAN}  Clone Cleanup${RESET}\n"

    for c in "${existing_clones[@]}"; do
        printf "  Existing: %s\n" "$c"
    done

    for c in "${removed_clones[@]}"; do
        printf "  Removed clone: %s\n" "$c"
    done

    for b in "${removed_branches[@]}"; do
        printf "  Removed branch: %s\n" "$b"
    done

    printf "${CYAN}${SEP}${RESET}\n"
}

_msg=$(_print_output | sed 's/\x1b\[[0-9;]*m//g')
_json_msg=$(printf '%s' "$_msg" | jq -Rs '.')
printf '{"systemMessage": %s}\n' "$_json_msg"
exit 0
