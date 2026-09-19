#!/usr/bin/env bash
#
# Shared primary-checkout sync, used by session_start.sh (every session start)
# and post_tool_use__sync_main_after_merge.sh (right after a `gh pr merge`
# succeeds, so the base repo does not sit stale for the rest of a long
# session). Sourced, never executed directly.

# _sync_primary_checkout_to_origin_main <primary-repo-root>
#
# Force-syncs the PRIMARY checkout (never a worktree) to origin/main,
# discarding anything local not on origin — intentional, no backup, so the
# base checkout of every repo always matches origin/main exactly. Every git
# call uses `-C`, never `cd`, so this never touches the caller's own cwd.
#
# checkout -f main can fail (e.g. another worktree already has main checked
# out) — in that case do NOT continue, or reset --hard would land on whatever
# branch is actually checked out instead of main. Confirmed via
# `branch --show-current` too, in case checkout "succeeds" but a detached
# HEAD or some other state leaves us not actually on main.
_sync_primary_checkout_to_origin_main() {
    local dir="$1"
    if git -C "$dir" checkout -f main >/dev/null 2>&1 \
        && [[ "$(git -C "$dir" branch --show-current 2>/dev/null)" == "main" ]]; then
        git -C "$dir" fetch origin --prune >/dev/null 2>&1 || true
        git -C "$dir" reset --hard origin/main >/dev/null 2>&1 || true
        git -C "$dir" clean -fd >/dev/null 2>&1 || true
    fi
}

# _cleanup_worktrees_and_branches <repo-root>
#
# Applies to every worktree `git worktree list` reports for the repo at
# <repo-root>, regardless of where it lives on disk. Drops:
#   - a worktree whose branch is gone from origin AND (merged into the
#     default branch OR its PR was closed without merging)
#   - a worktree untouched (no commits, no dirty files) for over 4 days
#   - a local branch whose upstream tracking is reported "gone"
#
# All state is `local` to this function (bash's dynamic scoping makes it
# visible to the nested helper functions this calls, same as when this logic
# lived at a script's top level) — nothing here leaks into the caller's shell.
#
# Runs from wherever it's called; every git call is `-C <repo-root>` or a
# `cd`-in-a-subshell, so this never touches the caller's own cwd.
_cleanup_worktrees_and_branches() {
    local git_root="$1"
    [[ -n "$git_root" ]] || return 0

    # Primary branch name, used below to check whether a feature branch's commits
    # are actually merged in (as opposed to just "absent from origin", which is
    # also true of a branch that was simply never pushed yet).
    local default_branch="main"
    git -C "$git_root" rev-parse --verify --quiet main >/dev/null 2>&1 || default_branch="master"

    # Drop stale administrative records first, so `git worktree list` reflects reality
    # even if a directory was deleted by hand.
    git -C "$git_root" worktree prune 2>/dev/null || true

    # Shared 4-day age cutoff, used both below (merged-branch cleanup) and by the
    # stale-worktree pass further down, so both paths agree on "how old is old".
    local age_cutoff=$(( $(date +%s) - 4*24*60*60 ))

    # Returns (echoes) the last-touched epoch time for a worktree: the newer of
    # its last commit time and the mtime of any uncommitted/untracked file in it.
    # Echoes 0 when it cannot be determined at all (no commits, no dirty files,
    # `git log` failed) so callers can fail closed instead of guessing.
    worktree_last_touched() {
        local path="$1"
        local last_commit last_touched status f _orig m entry
        last_commit=$(git -C "$path" log -1 --format=%ct 2>/dev/null)
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
            m=$(stat -f "%m" "${path}/${f}" 2>/dev/null) || continue
            (( m > last_touched )) && last_touched="$m"
        done < <(git -C "$path" status --porcelain -z 2>/dev/null)

        echo "$last_touched"
    }

    # Parse `git worktree list --porcelain`: records are blank-line separated, with a
    # `worktree <abs-path>` line and (unless detached) a `branch refs/heads/<name>` line.
    local wt_path=""
    local wt_branch=""
    process_worktree() {
        [[ -z "$wt_path" ]] && return
        # Never touch the main checkout.
        [[ "$wt_path" == "$git_root" ]] && return
        # Detached HEAD or no branch: leave it alone, we can't reason about its remote.
        [[ -z "$wt_branch" ]] && return

        if [[ $wt_branch == "main" || $wt_branch == "master" ]]; then
            return
        fi

        # Dirty gate: a worktree with uncommitted or untracked changes is never
        # removed here, no matter its merge/PR state — losing local edits nobody
        # pushed is the actual risk, not the worktree's age. (The age-based gate
        # this replaced was a proxy for the same risk and is redundant now that
        # the ahead_count/PR-state checks below already rule out the false-positive
        # "brand-new branch looks merged" case that motivated it — confirmed live,
        # 2026-08-30.)
        if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
            return
        fi

        if git -C "$git_root" ls-remote --heads origin "$wt_branch" 2>/dev/null | grep -qF "refs/heads/$wt_branch"; then
            return
        fi

        # Branch missing from origin can mean "PR merged, branch deleted upstream"
        # (safe to drop) OR "local branch never pushed yet" (must NOT drop — this
        # false positive is what destroyed a live, unpushed worktree previously).
        # Safe to drop if EITHER its commits are already ancestors of the local
        # default branch (merged), OR its PR was closed without merging on GitHub
        # (abandoned). If neither can be confirmed, leave it alone.
        #
        # `merge-base --is-ancestor` is trivially true for a BRAND-NEW branch that
        # hasn't diverged from main yet (0 commits ahead) — it's the same commit,
        # so it looks "merged" even though nothing was ever merged. That false
        # positive is what destroyed several genuinely fresh, in-progress worktrees
        # (confirmed live, 2026-08-30). Only trust the ancestor check once the
        # branch has actually diverged; a branch with 0 commits ahead must fall
        # through to the PR-state check like any other unconfirmed case.
        local ahead_count pr_state
        ahead_count=$(git -C "$git_root" rev-list --count "$default_branch".."$wt_branch" 2>/dev/null || echo 0)
        if [[ "$ahead_count" == "0" ]] || ! git -C "$git_root" merge-base --is-ancestor "$wt_branch" "$default_branch" 2>/dev/null; then
            pr_state=$(cd "$git_root" && gh pr view "$wt_branch" --json state -q .state 2>/dev/null) || true
            if [[ "$pr_state" != "MERGED" && "$pr_state" != "CLOSED" ]]; then
                return
            fi
        fi

        # Branch is gone upstream, and either merged or its PR was closed.
        # --force is needed because the worktree may hold untracked leftovers
        # (node_modules, .venv, symlinked .env files).
        git -C "$git_root" worktree remove --force "$wt_path" 2>/dev/null || true
    }

    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt_path="${line#worktree }" ;;
            "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
            "") process_worktree; wt_path=""; wt_branch="" ;;
        esac
    done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null)
    # The last record may not be followed by a blank line.
    process_worktree

    # Removing a worktree can leave its branch behind; prune the admin files again.
    git -C "$git_root" worktree prune 2>/dev/null || true

    # --- Stale worktree cleanup (untouched >4 days) ---
    # Beyond the "branch deleted upstream" check above, also drop any worktree
    # `git worktree list` reports (wherever it lives on disk) that has had no
    # commits and no uncommitted file changes in over 4 days — abandoned
    # agent/feature worktrees that would otherwise sit around eating disk space.
    # Uses the same `age_cutoff` (4 days) computed above. Unlike process_worktree,
    # this pass has no merge/PR confirmation to lean on, so age is the only signal
    # available and stays load-bearing here.
    local cwd_real
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
        # back to raw filesystem mtimes with the same 4-day cutoff before treating
        # it as abandoned enough to delete outright.
        if ! git -C "$wt_path" rev-parse --git-dir >/dev/null 2>&1; then
            local broken_cutoff_str
            broken_cutoff_str=$(date -v-4d "+%Y-%m-%d %H:%M:%S")
            # Skip node_modules/.next/build caches — their mtimes reflect tooling
            # churn, not real edits, and would mask genuinely abandoned worktrees.
            if find "$wt_path" \( -name node_modules -o -name .next -o -name dist -o -name build -o -name .venv \) -prune -o -type f -newermt "$broken_cutoff_str" -print -quit 2>/dev/null | grep -q .; then
                return
            fi
            rm -rf "$wt_path" 2>/dev/null || true
            return
        fi

        local last_touched
        last_touched=$(worktree_last_touched "$wt_path")

        # Could not determine any timestamp (no commits, no dirty files, and git log
        # failed) — fail closed and keep it rather than guessing a cutoff-equal value.
        if [[ "$last_touched" == "0" ]]; then
            return
        fi

        (( last_touched > age_cutoff )) && return

        git -C "$git_root" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path" 2>/dev/null || true
    }

    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt_path="${line#worktree }" ;;
            "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
            "") process_stale_worktree; wt_path=""; wt_branch="" ;;
        esac
    done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null)
    process_stale_worktree

    git -C "$git_root" worktree prune 2>/dev/null || true

    # Clean local branches with gone tracking
    while read -r line; do
        [[ $line =~ ^[*+] ]] && continue
        local branch
        branch=$(echo "$line" | awk '{print $1}')
        [[ $branch == "main" || $branch == "master" ]] && continue
        echo "$line" | grep -q ': gone]' || continue
        git -C "$git_root" branch -D "$branch" 2>/dev/null || true
    done < <(git -C "$git_root" branch -vv)
}
