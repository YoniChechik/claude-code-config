#!/usr/bin/env bash
# Unified startup hook: git sync, worktree cleanup (merged-branch + stale >2d). Silent, always exits 0.

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
# Applies to every worktree `git worktree list` reports, regardless of where it
# lives on disk. Drop any whose branch no longer exists on origin (i.e. the PR
# was merged and the branch deleted).

# Primary branch name, used below to check whether a feature branch's commits
# are actually merged in (as opposed to just "absent from origin", which is
# also true of a branch that was simply never pushed yet).
default_branch="main"
git rev-parse --verify --quiet main >/dev/null 2>&1 || default_branch="master"

# Drop stale administrative records first, so `git worktree list` reflects reality
# even if a directory was deleted by hand.
git worktree prune 2>/dev/null || true

# Parse `git worktree list --porcelain`: records are blank-line separated, with a
# `worktree <abs-path>` line and (unless detached) a `branch refs/heads/<name>` line.
wt_path=""
wt_branch=""
process_worktree() {
    [[ -z "$wt_path" ]] && return
    # Never touch the main checkout.
    [[ "$wt_path" == "$git_root" ]] && return
    # Detached HEAD or no branch: leave it alone, we can't reason about its remote.
    [[ -z "$wt_branch" ]] && return

    if [[ $wt_branch == "main" || $wt_branch == "master" ]]; then
        return
    fi

    if git ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -qF "refs/heads/$wt_branch"; then
        return
    fi

    # Branch missing from origin can mean "PR merged, branch deleted upstream"
    # (safe to drop) OR "local branch never pushed yet" (must NOT drop — this
    # false positive is what destroyed a live, unpushed worktree previously).
    # Safe to drop if EITHER its commits are already ancestors of the local
    # default branch (merged), OR its PR was closed without merging on GitHub
    # (abandoned). If neither can be confirmed, leave it alone.
    if ! git merge-base --is-ancestor "$wt_branch" "$default_branch" 2>/dev/null; then
        pr_state=$(cd "$git_root" && gh pr view "$wt_branch" --json state -q .state 2>/dev/null)
        if [[ "$pr_state" != "MERGED" && "$pr_state" != "CLOSED" ]]; then
            return
        fi
    fi

    # Branch is gone upstream, and either merged or its PR was closed.
    # --force is needed because the worktree may hold untracked leftovers
    # (node_modules, .venv, symlinked .env files).
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

# --- Stale worktree cleanup (untouched >2 days) ---
# Beyond the "branch deleted upstream" check above, also drop any worktree
# `git worktree list` reports (wherever it lives on disk) that has had no
# commits and no uncommitted file changes in over 2 days — abandoned
# agent/feature worktrees that would otherwise sit around eating disk space.
stale_cutoff=$(( $(date +%s) - 2*24*60*60 ))
cwd_real=$(pwd -P)

wt_path=""
wt_branch=""
process_stale_worktree() {
    [[ -z "$wt_path" ]] && return
    # Never touch the main checkout.
    [[ "$wt_path" == "$git_root" ]] && return
    [[ -n "$wt_branch" && ( "$wt_branch" == "main" || "$wt_branch" == "master" ) ]] && return
    # Never remove the worktree we're currently sitting in.
    [[ "$cwd_real" == "$wt_path" || "$cwd_real" == "$wt_path"/* ]] && return

    # Broken worktree admin metadata ("not a git repository"): git can't be
    # trusted to tell us about commits or uncommitted changes here, so fall
    # back to raw filesystem mtimes with a longer, more conservative 3-day
    # cutoff before treating it as abandoned enough to delete outright.
    if ! git -C "$wt_path" rev-parse --git-dir >/dev/null 2>&1; then
        broken_cutoff_str=$(date -v-3d "+%Y-%m-%d %H:%M:%S")
        # Skip node_modules/.next/build caches — their mtimes reflect tooling
        # churn, not real edits, and would mask genuinely abandoned worktrees.
        if find "$wt_path" \( -name node_modules -o -name .next -o -name dist -o -name build -o -name .venv \) -prune -o -type f -newermt "$broken_cutoff_str" -print -quit 2>/dev/null | grep -q .; then
            return
        fi
        rm -rf "$wt_path" 2>/dev/null || true
        return
    fi

    last_commit=$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null)
    last_touched="${last_commit:-0}"

    # -z gives NUL-delimited records (safe for spaces); a rename/copy record is
    # "XY new-path\0orig-path\0" — skip the extra orig-path token, stat new-path.
    while IFS= read -r -d '' entry; do
        status="${entry:0:2}"
        f="${entry:3}"
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            IFS= read -r -d '' _orig
        fi
        [[ -z "$f" ]] && continue
        m=$(stat -f "%m" "${wt_path}/${f}" 2>/dev/null) || continue
        (( m > last_touched )) && last_touched="$m"
    done < <(git -C "$wt_path" status --porcelain -z 2>/dev/null)

    # Could not determine any timestamp (no commits, no dirty files, and git log
    # failed) — fail closed and keep it rather than guessing a cutoff-equal value.
    if [[ "$last_touched" == "0" ]]; then
        return
    fi

    (( last_touched > stale_cutoff )) && return

    git worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path" 2>/dev/null || true
}

while IFS= read -r line; do
    case "$line" in
        "worktree "*) wt_path="${line#worktree }" ;;
        "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
        "") process_stale_worktree; wt_path=""; wt_branch="" ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null)
process_stale_worktree

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
