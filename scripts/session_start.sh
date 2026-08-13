#!/usr/bin/env bash
# Unified startup hook: git sync, worktree cleanup. Silent, always exits 0.

git_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [[ -z "$git_root" ]]; then
    exit 0
fi

# --- Single fetch with prune ---
git fetch -p >/dev/null 2>&1 || true

# --- Git merge --ff-only (using already-fetched data) ---
current_branch=$(git branch --show-current 2>/dev/null)
if [[ -n "$current_branch" ]] && git rev-parse --verify "origin/$current_branch" &>/dev/null; then
    git merge --ff-only "origin/$current_branch" >/dev/null 2>&1 || true
fi

# --- Worktree cleanup ---
# Feature worktrees live at <repo-root>/.claude/worktrees/<name>. Drop any whose
# branch no longer exists on origin (i.e. the PR was merged and the branch deleted).
worktrees_dir="${git_root}/.claude/worktrees"

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

    if [[ $wt_branch == "main" || $wt_branch == "master" ]]; then
        return
    fi

    if git ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -qF "refs/heads/$wt_branch"; then
        return
    fi

    # Branch is gone upstream. --force is needed because the worktree may hold
    # untracked leftovers (node_modules, .venv, symlinked .env files).
    git worktree remove --force "$wt_path" 2>/dev/null || true
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
while read -r line; do
    [[ $line =~ ^[*+] ]] && continue
    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue
    echo "$line" | grep -q ': gone]' || continue
    git branch -D "$branch" 2>/dev/null || true
done < <(git branch -vv)

# --- RTK update ---
# Silently upgrade RTK via brew and re-run `rtk init -g` to keep Claude Code
# hook files up to date. Must be fast and non-blocking — runs every session start.

# Maintainer-recommended upgrade path (github.com/rtk-ai/rtk#190): `brew update`
# first so the formula index isn't stale, then `brew upgrade rtk`. Both are no-ops
# (exit 0) when already current. Suppress output; `|| true` ensures a non-zero
# exit from brew never propagates.
brew update 2>/dev/null || true
brew upgrade rtk 2>/dev/null || true

# Re-run `rtk init -g` to refresh the global hook files that RTK injects into
# Claude Code (e.g. the `rtk hook claude` PreToolUse hook). `-g` targets the
# global Claude config (~/.claude). Pipe `yes` so any yes/no prompts auto-accept.
# Suppress all output; we only care that it runs.
yes | rtk init -g 2>/dev/null || true

exit 0
