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
# Capture the fetch exit status: a NON-zero status means we are likely offline /
# the remote is unreachable. Worktree cleanup below uses this to AVOID treating
# "branch not found on origin" as "branch was deleted" when we never reached origin.
fetch_output=$(git fetch -p 2>&1)
fetch_exit=$?

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
# Safely remove feature worktrees whose branch has been deleted from origin.
# Worktrees share the base repo's object store, so removal MUST go through
# `git worktree remove` (never `rm -rf`) to also deregister the worktree.
removed_worktrees=()
existing_worktrees=()
skipped_worktrees=()

# Prune stale registry entries FIRST: drops records whose on-disk path is gone,
# so we never attempt to `remove` a path that no longer exists.
git worktree prune 2>/dev/null || true

# Identify the MAIN worktree explicitly. We CANNOT trust $git_root here: if the
# session started inside a linked worktree (e.g. _worktrees/foo), $git_root points
# at that linked worktree, not the base repo. The first `worktree` record of
# `git worktree list --porcelain` is always the main worktree.
main_worktree=""
while IFS= read -r line; do
    if [[ $line == worktree\ * ]]; then
        main_worktree="${line#worktree }"
        break
    fi
done < <(git worktree list --porcelain 2>/dev/null)

# Parse `git worktree list --porcelain`. Records are separated by blank lines and
# contain a `worktree <path>` line, optionally a `branch refs/heads/<name>` line
# (absent for detached HEAD), and optionally a `locked` line.
wt_path=""
wt_branch=""
wt_locked=0

# Flush one parsed worktree record through the cleanup decision logic.
process_worktree() {
    # Nothing to do if we never captured a path (e.g. leading blank line).
    [[ -z "$wt_path" ]] && return

    local dir_name
    dir_name=$(basename "$wt_path")

    # NEVER touch the main worktree.
    if [[ "$wt_path" == "$main_worktree" ]]; then
        return
    fi

    # Skip & report locked worktrees: the user (or another process) pinned them.
    if [[ $wt_locked -eq 1 ]]; then
        skipped_worktrees+=("$dir_name (locked)")
        return
    fi

    # Skip records with no branch (detached HEAD) — we can't reason about origin.
    if [[ -z "$wt_branch" ]]; then
        skipped_worktrees+=("$dir_name (detached HEAD)")
        return
    fi

    # Keep main/master worktrees around.
    if [[ "$wt_branch" == "main" || "$wt_branch" == "master" ]]; then
        existing_worktrees+=("$dir_name")
        return
    fi

    # Gate remote-gone deletions on a SUCCESSFUL fetch. If we were offline, an
    # empty ls-remote result does NOT mean the branch was deleted, so keep it.
    if [[ $fetch_exit -ne 0 ]]; then
        skipped_worktrees+=("$dir_name (offline: fetch failed)")
        return
    fi

    # If the branch still exists on origin, the worktree is in active use — keep it.
    if git ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -qF "refs/heads/$wt_branch"; then
        existing_worktrees+=("$dir_name")
        return
    fi

    # Branch is confirmed gone from origin. Check dirtiness BEFORE removing:
    # any tracked change OR untracked file means we must NOT discard work.
    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        skipped_worktrees+=("$dir_name (dirty)")
        return
    fi

    # Clean + branch gone: remove WITHOUT --force so git refuses if anything is
    # unexpectedly amiss, and so the worktree is properly deregistered.
    if git worktree remove "$wt_path" 2>/dev/null; then
        removed_worktrees+=("$dir_name")
    else
        skipped_worktrees+=("$dir_name (remove failed)")
    fi
}

while IFS= read -r line; do
    case "$line" in
        worktree\ *)
            wt_path="${line#worktree }"
            ;;
        branch\ refs/heads/*)
            wt_branch="${line#branch refs/heads/}"
            ;;
        locked*)
            wt_locked=1
            ;;
        "")
            # Blank line ends a record: process it and reset accumulators.
            process_worktree
            wt_path=""
            wt_branch=""
            wt_locked=0
            ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null)
# Flush the final record (porcelain output may not end with a trailing blank line).
process_worktree

# Build the set of branches still attached to a SKIPPED worktree so the branch
# prune loop below never deletes a branch we deliberately kept (dirty/locked/etc).
# `git worktree list` already reflects removals done above (removed worktrees
# free their branch, so those branches remain eligible for pruning).
protected_branches=()
while IFS= read -r line; do
    [[ $line == branch\ refs/heads/* ]] && protected_branches+=("${line#branch refs/heads/}")
done < <(git worktree list --porcelain 2>/dev/null)

# Clean local branches whose upstream is gone, EXCEPT any branch still checked
# out in a (skipped) worktree — those are protected.
removed_branches=()
while read -r line; do
    [[ $line =~ ^[*+] ]] && continue
    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue
    echo "$line" | grep -q ': gone]' || continue

    # Never delete a branch still attached to a worktree (the skipped ones).
    is_protected=0
    for protected in "${protected_branches[@]}"; do
        [[ "$branch" == "$protected" ]] && is_protected=1 && break
    done
    [[ $is_protected -eq 1 ]] && continue

    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

# Output worktrees section only if there's something to report.
if [[ ${#existing_worktrees[@]} -gt 0 || ${#removed_worktrees[@]} -gt 0 || ${#skipped_worktrees[@]} -gt 0 || ${#removed_branches[@]} -gt 0 ]]; then
    add_line "Worktrees:"
    for worktree in "${existing_worktrees[@]}"; do
        add_line "  Existing: $worktree"
    done
    for worktree in "${removed_worktrees[@]}"; do
        add_line "  Removed: $worktree"
    done
    for worktree in "${skipped_worktrees[@]}"; do
        add_line "  Skipped: $worktree"
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
