#!/usr/bin/env bash
# Unified startup hook: git sync, worktree cleanup (merged-branch + stale >4d). Silent, always exits 0.

git_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [[ -z "$git_root" ]]; then
    exit 0
fi

# Hoisted above the worktree-vs-primary-checkout branch below: the cleanup
# pass runs unconditionally for BOTH cases, so the library must already be
# loaded before that branch, not only inside the primary-checkout arm.
GIT_SYNC_LIB_LOADED=0
# shellcheck source=./_git_sync.sh
if source "$(dirname "${BASH_SOURCE[0]}")/_git_sync.sh" 2>/dev/null; then
    GIT_SYNC_LIB_LOADED=1
fi

# --- Git sync ---
# A linked worktree (git-dir under <common-dir>/worktrees/<name>) keeps the
# original behavior: fetch, then ff-only-merge the current branch. The primary
# checkout instead force-syncs to origin/main, discarding anything local not
# on origin — intentional, no backup, so the base checkout of every repo a
# session starts in always matches origin/main exactly.
git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || true

if [[ "$git_dir" == *"/worktrees/"* ]]; then
    git fetch -p >/dev/null 2>&1 || true
    current_branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$current_branch" ]] && git rev-parse --verify "origin/$current_branch" &>/dev/null; then
        git merge --ff-only "origin/$current_branch" >/dev/null 2>&1 || true
    fi
elif [[ "$GIT_SYNC_LIB_LOADED" == "1" ]]; then
    _sync_primary_checkout_to_origin_main "$git_root"
fi

if [[ "$GIT_SYNC_LIB_LOADED" == "1" ]]; then
    _cleanup_worktrees_and_branches "$git_root"
fi

# --- RTK update (cooldown-gated) ---
# Silently upgrade RTK via brew and re-run `rtk init -g` to keep Claude Code
# hook files up to date. This hook runs on EVERY session start, in EVERY
# repo — without a cooldown that's 3 network/brew calls per session, every
# session. A timestamp marker gates only how OFTEN this block runs; what
# `brew update`/`brew upgrade rtk`/`rtk init -g` themselves do is unchanged.
RTK_UPDATE_MARKER="${RTK_UPDATE_MARKER:-/tmp/.claude_session_start_rtk_update}"
RTK_UPDATE_COOLDOWN_SECONDS=$((6 * 60 * 60)) # 6 hours

last_run=0
if [[ -f "$RTK_UPDATE_MARKER" ]]; then
    last_run=$(cat "$RTK_UPDATE_MARKER" 2>/dev/null)
    # Fail closed (treat as "never run") on a missing/corrupt marker so a
    # garbled file can't wedge the update off forever.
    [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
fi
now=$(date +%s)

if (( now - last_run >= RTK_UPDATE_COOLDOWN_SECONDS )); then
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

    echo "$now" > "$RTK_UPDATE_MARKER" 2>/dev/null || true
fi

exit 0
