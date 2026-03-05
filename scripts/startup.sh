#!/usr/bin/env bash
# Unified startup hook: env validation, git sync, clone cleanup.
# Outputs a single JSON systemMessage line. Always exits 0.

output=""
add_line() { output+="$1"$'\n'; }

# Simple bash JSON escape: replace \ with \\, " with \", newlines with \n
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "\"$s\""
}

# --- Environment validation ---
env_issues=()

if ! command -v jq &>/dev/null; then
    env_issues+=("jq is not installed")
fi

git_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [[ -z "$git_root" ]]; then
    env_issues+=("not a git repository")
fi

if [[ ${#env_issues[@]} -gt 0 ]]; then
    add_line "Environment issues:"
    for issue in "${env_issues[@]}"; do
        add_line "  - $issue"
    done
else
    add_line "Environment: OK"
fi

# If not a git repo or jq missing, skip git operations
if [[ -z "$git_root" ]] || ! command -v jq &>/dev/null; then
    printf '%s\n' "{\"systemMessage\": $(json_escape "$output")}"
    exit 0
fi

# --- Single fetch with prune ---
fetch_output=$(git fetch -p 2>&1) || true

# --- Git merge --ff-only (using already-fetched data) ---
current_branch=$(git branch --show-current 2>/dev/null)
if [[ -n "$current_branch" ]]; then
    if ! git rev-parse --verify "origin/$current_branch" &>/dev/null; then
        add_line "Git: up to date"
    else
        merge_output=$(git merge --ff-only "origin/$current_branch" 2>&1)
        merge_exit=$?

        if [[ $merge_exit -eq 0 ]]; then
            if echo "$merge_output" | grep -q "Already up to date"; then
                add_line "Git: up to date"
            else
                add_line "Git: merged"
            fi
        else
            error_msg=$(echo "$merge_output" | head -1)
            add_line "Git: error: $error_msg"
        fi
    fi
else
    add_line "Git: no current branch (detached HEAD)"
fi

# --- Clone cleanup ---
clones_dir="${git_root}/_clones"
removed_clones=()
existing_clones=()

if [[ -d "$clones_dir" ]]; then
    for clone_dir in "${clones_dir}"/*; do
        [[ ! -d "$clone_dir" ]] && continue
        [[ ! -d "$clone_dir/.git" ]] && continue

        branch=$(git -C "$clone_dir" branch --show-current 2>/dev/null)
        [[ -z "$branch" ]] && continue

        dir_name=$(basename "$clone_dir")

        if [[ $branch == "main" || $branch == "master" ]]; then
            existing_clones+=("$dir_name")
            continue
        fi

        if git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "refs/heads/$branch"; then
            existing_clones+=("$dir_name")
            continue
        fi

        if rm -rf "$clone_dir" 2>/dev/null; then
            removed_clones+=("$dir_name")
        fi
    done
fi

# Clean local branches with gone tracking
removed_branches=()
while read -r line; do
    [[ $line == \** ]] && continue
    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue
    echo "$line" | grep -q ': gone]' || continue
    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

# Output clones section only if there's something to report
if [[ ${#existing_clones[@]} -gt 0 || ${#removed_clones[@]} -gt 0 || ${#removed_branches[@]} -gt 0 ]]; then
    add_line "Clones:"
    for clone in "${existing_clones[@]}"; do
        add_line "  Existing: $clone"
    done
    for clone in "${removed_clones[@]}"; do
        add_line "  Removed: $clone"
    done
    for branch in "${removed_branches[@]}"; do
        add_line "  Removed branch: $branch"
    done
fi

# --- Output JSON systemMessage ---
printf '%s\n' "{\"systemMessage\": $(printf '%s' "$output" | jq -Rs .)}"
exit 0
