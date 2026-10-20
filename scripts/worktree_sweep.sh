#!/usr/bin/env bash

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

if [[ -z "${WORKTREE_SWEEP_DETACHED:-}" ]]; then
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
    WORKTREE_SWEEP_DETACHED=1 WORKTREE_SWEEP_ROOT="$git_root" \
        nohup bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 </dev/null &
    exit 0
fi

HOOK_NAME=worktree_sweep
source "$HOOK_DIR/_git_sync.sh" 2>/dev/null || exit 0
cd / || exit 0
sleep "${WORKTREE_SWEEP_DELAY:-5}"
_cleanup_worktrees_and_branches "$WORKTREE_SWEEP_ROOT"
exit 0
