#!/usr/bin/env bash
# Unified startup hook: env validation, git sync, worktree cleanup.
# Outputs a single JSON systemMessage line. Always exits 0.

# ── Stdin payload (consumed once, early, before anything else reads it) ──────
INPUT=$(cat)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null || true)

output=""
add_line() { output+="$1"$'\n'; }

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
    printf '%s\n' "{\"systemMessage\": $(printf '%s' "$output" | jq -Rs .)}"
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

# --- Worktree cleanup ---
# Feature worktrees live at <repo-root>/.claude/worktrees/<name>. Drop any whose
# branch no longer exists on origin (i.e. the PR was merged and the branch deleted).
worktrees_dir="${git_root}/.claude/worktrees"
removed_worktrees=()
existing_worktrees=()

# Drop stale administrative records first, so `git worktree list` reflects reality
# even if a directory was deleted by hand.
git worktree prune 2>/dev/null || true

# Parse `git worktree list --porcelain`: records are blank-line separated, with a
# `worktree <abs-path>` line and (unless detached) a `branch refs/heads/<name>` line.
wt_path=""
wt_branch=""
process_worktree() {
    # Only consider worktrees under .claude/worktrees — never the main checkout.
    [[ -z "$wt_path" ]] && return
    [[ "$wt_path" != "${worktrees_dir}/"* ]] && return
    # Detached HEAD or no branch: leave it alone, we can't reason about its remote.
    [[ -z "$wt_branch" ]] && return

    local dir_name
    dir_name=$(basename "$wt_path")

    if [[ $wt_branch == "main" || $wt_branch == "master" ]]; then
        existing_worktrees+=("$dir_name")
        return
    fi

    if git ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -qF "refs/heads/$wt_branch"; then
        existing_worktrees+=("$dir_name")
        return
    fi

    # Branch is gone upstream. --force is needed because the worktree may hold
    # untracked leftovers (node_modules, .venv, symlinked .env files).
    if git worktree remove --force "$wt_path" 2>/dev/null; then
        removed_worktrees+=("$dir_name")
    else
        existing_worktrees+=("$dir_name")
    fi
}

while IFS= read -r line; do
    case "$line" in
        "worktree "*) wt_path="${line#worktree }" ;;
        "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
        "") process_worktree; wt_path=""; wt_branch="" ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null)
# The last record may not be followed by a blank line.
process_worktree

# Removing a worktree can leave its branch behind; prune the admin files again.
git worktree prune 2>/dev/null || true

# Clean local branches with gone tracking
removed_branches=()
while read -r line; do
    [[ $line =~ ^[*+] ]] && continue
    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue
    echo "$line" | grep -q ': gone]' || continue
    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

# Output worktrees section only if there's something to report
if [[ ${#existing_worktrees[@]} -gt 0 || ${#removed_worktrees[@]} -gt 0 || ${#removed_branches[@]} -gt 0 ]]; then
    add_line "Worktrees:"
    for wt in "${existing_worktrees[@]}"; do
        add_line "  Existing: $wt"
    done
    for wt in "${removed_worktrees[@]}"; do
        add_line "  Removed: $wt"
    done
    for branch in "${removed_branches[@]}"; do
        add_line "  Removed branch: $branch"
    done
fi

# --- Resume detection ---
if [[ "$SOURCE" == "resume" ]]; then
    add_line ""
    add_line "RESUME DETECTED: Immediately invoke /continue-feature to restore working context for the active feature branch."
fi

# --- Output JSON systemMessage ---
printf '%s\n' "{\"systemMessage\": $(printf '%s' "$output" | jq -Rs .)}"
exit 0
