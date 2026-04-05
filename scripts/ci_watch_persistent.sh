#!/usr/bin/env bash
#
# CI Watcher
# ==========
# Monitors GitHub Actions CI status for a branch and reports results.
#
# Architecture:
#   Single flat while-true loop with function-based structure.
#   No nested loops, no timeouts, no exit-on-inactivity.
#
# Exit conditions:
#   - No branch argument provided (exit 1)
#   - PR merged and main CI resolved for the merge commit (exit 0)
#
# Notification (non-exit) conditions:
#   - CI failed — notifies via webhook and keeps watching
#   - Merge conflict detected — notifies via webhook and keeps watching
#   - Branch behind — notifies via webhook and keeps watching
#
# SHA tracking:
#   The script tracks commits by SHA, not by branch name. It resolves the branch
#   to a SHA at startup, then detects new pushes by comparing the headSha from
#   GitHub's run list against the tracked SHA. This avoids needing `git fetch`.
#
# Dedup-by-workflow:
#   When multiple runs exist for the same workflow name (e.g. re-runs), the script
#   groups by workflow name and keeps only the latest run (highest databaseId) per
#   workflow, so stale re-run results don't pollute the status.
#
# Merge tracking:
#   When the PR is merged, the script switches to tracking CI on the default branch
#   for the merge commit SHA. It exits cleanly once main CI passes or fails.
#
set -euo pipefail

# --- Configuration ---
BRANCH="${1:?Usage: ci_watch_persistent.sh <branch>}"
POLL_INTERVAL=5
LATEST_SHA=$(gh api "repos/{owner}/{repo}/commits/$BRANCH" --jq '.sha')
REPORTED_PASS=""
REPORTED_FAIL=""
REPORTED_CONFLICT=""
REPORTED_BEHIND=""
RUNS_JSON=""
SHA_RUNS=""
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
MERGED=""
MERGE_COMMIT_SHA=""
MAIN_RUNS_JSON=""
REPORTED_MAIN_PASS=""
REPORTED_MAIN_FAIL=""

# --- Functions ---

fetch_runs() {
    RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)
}

check_merge_conflict() {
    MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
    if [ "$MERGEABLE" = "CONFLICTING" ]; then
        if [ -z "$REPORTED_CONFLICT" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: PR has merge conflicts. Delegate the fix to coder-agent." || true
            REPORTED_CONFLICT=1
        fi
    else
        REPORTED_CONFLICT=""
    fi
}

check_branch_behind() {
    MERGE_STATE=$(gh pr view "$BRANCH" --json mergeStateStatus --jq '.mergeStateStatus' 2>&1) || MERGE_STATE=""
    if [ "$MERGE_STATE" = "BEHIND" ]; then
        if [ -z "$REPORTED_BEHIND" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: PR is behind the base branch and needs to be updated. Run /sync to update the branch." || true
            REPORTED_BEHIND=1
        fi
    else
        REPORTED_BEHIND=""
    fi
}

detect_new_sha() {
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
        echo "New push detected on branch '$BRANCH' (new SHA: $CURRENT_SHA). Now tracking new CI run."
        LATEST_SHA="$CURRENT_SHA"
        REPORTED_PASS=""
        REPORTED_FAIL=""
        REPORTED_CONFLICT=""
        REPORTED_BEHIND=""
    fi
}

get_sha_runs_for() {
    local runs_json="$1"
    local sha="$2"
    SHA_RUNS=$(echo "$runs_json" | jq --arg sha "$sha" '
      [.[] | select(.headSha == $sha)]
      | group_by(.name)
      | map(sort_by(.databaseId) | last)
    ')
}

get_sha_runs() {
    get_sha_runs_for "$RUNS_JSON" "$LATEST_SHA"
}

check_failures() {
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
        FAILED_NAMES=$(echo "$FAILED_RUNS" | jq -r '.[].name' | paste -sd ', ' -)
        FAILED_IDS=$(echo "$FAILED_RUNS" | jq -r '.[].databaseId')

        ALL_FAILED_JOBS=""
        while IFS= read -r RUN_ID; do
            FAILED_JOBS=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null || true)
            if [ -n "$FAILED_JOBS" ]; then
                ALL_FAILED_JOBS="${ALL_FAILED_JOBS}${FAILED_JOBS}"$'\n'
            fi
        done <<< "$FAILED_IDS"

        FIRST_FAILED_ID=$(echo "$FAILED_RUNS" | jq -r '.[0].databaseId')
        MSG="CI failed on branch '$BRANCH' (workflows: $FAILED_NAMES)."
        if [ -n "$ALL_FAILED_JOBS" ]; then
            MSG="${MSG} Failed jobs: ${ALL_FAILED_JOBS}"
        fi
        MSG="${MSG} Run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs."
        MSG="${MSG} Delegate the fix to coder-agent."
        if [ -z "$REPORTED_FAIL" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: $MSG" || true
            REPORTED_FAIL=1
        fi
    fi
}

check_all_passed() {
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
        if [ -z "$REPORTED_PASS" ]; then
            bash "$HOME/.claude/channel/notify.sh" "✅ CI passed on branch $BRANCH" || true
            REPORTED_PASS=1
        fi
    fi
}

check_main_failures() {
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
        FAILED_NAMES=$(echo "$FAILED_RUNS" | jq -r '.[].name' | paste -sd ', ' -)
        FAILED_IDS=$(echo "$FAILED_RUNS" | jq -r '.[].databaseId')

        ALL_FAILED_JOBS=""
        while IFS= read -r RUN_ID; do
            FAILED_JOBS=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null || true)
            if [ -n "$FAILED_JOBS" ]; then
                ALL_FAILED_JOBS="${ALL_FAILED_JOBS}${FAILED_JOBS}"$'\n'
            fi
        done <<< "$FAILED_IDS"

        FIRST_FAILED_ID=$(echo "$FAILED_RUNS" | jq -r '.[0].databaseId')
        MSG="CI on $DEFAULT_BRANCH failed for merge of '$BRANCH' (workflows: $FAILED_NAMES)."
        if [ -n "$ALL_FAILED_JOBS" ]; then
            MSG="${MSG} Failed jobs: ${ALL_FAILED_JOBS}"
        fi
        MSG="${MSG} Run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs."
        if [ -z "$REPORTED_MAIN_FAIL" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on $DEFAULT_BRANCH for merge of $BRANCH: $MSG" || true
            REPORTED_MAIN_FAIL=1
        fi
    fi
}

check_main_all_passed() {
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
        if [ -z "$REPORTED_MAIN_PASS" ]; then
            bash "$HOME/.claude/channel/notify.sh" "✅ CI on $DEFAULT_BRANCH passed for merge of $BRANCH" || true
            REPORTED_MAIN_PASS=1
        fi
    fi
}

check_merged() {
    local result
    result=$(gh pr view "$BRANCH" --json state,mergeCommit \
        --jq 'select(.state == "MERGED") | .mergeCommit.oid' 2>/dev/null || true)
    if [ -n "$result" ]; then
        MERGED=1
        MERGE_COMMIT_SHA="$result"
        echo "PR for branch '$BRANCH' has been merged (merge commit: $MERGE_COMMIT_SHA). Now tracking CI on $DEFAULT_BRANCH."
    fi
}

fetch_main_runs() {
    MAIN_RUNS_JSON=$(gh run list --branch "$DEFAULT_BRANCH" --json databaseId,status,conclusion,name,headSha)
}

# --- Main loop ---

while true; do

    # --- Check if PR was merged ---
    if [ -z "$MERGED" ]; then
        check_merged
    fi

    # --- Merged path: track main CI for the merge commit ---
    if [ -n "$MERGED" ]; then
        fetch_main_runs
        get_sha_runs_for "$MAIN_RUNS_JSON" "$MERGE_COMMIT_SHA"

        if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        check_main_failures
        check_main_all_passed

        if [ -n "$REPORTED_MAIN_PASS" ] || [ -n "$REPORTED_MAIN_FAIL" ]; then
            echo "Main CI resolved for merge of '$BRANCH'. Exiting."
            exit 0
        fi

        sleep "$POLL_INTERVAL"
        continue
    fi

    # --- Branch tracking path (existing logic) ---
    fetch_runs

    check_merge_conflict
    check_branch_behind

    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    detect_new_sha

    if [ -n "$REPORTED_PASS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    get_sha_runs

    if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    check_failures
    check_all_passed

    sleep "$POLL_INTERVAL"
done
