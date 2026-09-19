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
