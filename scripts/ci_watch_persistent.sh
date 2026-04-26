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
#   - Branch does not exist on remote (exit 1)
#   - PR merged and main CI resolved for the merge commit — pass or fail (exit 0)
#   - Timeout waiting for main CI runs after merge (exit 0)
#
# Notification (non-exit) conditions:
#   - CI failed on branch — notifies via webhook and keeps watching
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
# First argument: webhook HTTP port (used to send notifications via curl)
# Second argument: branch name to watch
PORT="${1:?Usage: ci_watch_persistent.sh <port> <branch> <session_token>}"
BRANCH="${2:?Usage: ci_watch_persistent.sh <port> <branch> <session_token>}"
SESSION_TOKEN="${3:?Usage: ci_watch_persistent.sh <port> <branch> <session_token>}"
POLL_INTERVAL=5
LATEST_SHA=$(gh api "repos/{owner}/{repo}/commits/$BRANCH" --jq '.sha' 2>/dev/null) || {
    echo "Error: could not resolve branch '$BRANCH' to a SHA. Does the branch exist on the remote?" >&2
    exit 1
}
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
MERGEABLE=""
REPORTED_MAIN_PASS=""
REPORTED_MAIN_FAIL=""
MAIN_WAIT_ITERATIONS=0
MAIN_WAIT_MAX=60  # 60 * 5s = 5 minutes

# --- Functions ---

fetch_runs_for() {
    local branch="$1"
    gh run list --branch "$branch" --json databaseId,status,conclusion,name,headSha
}

# Generic PR-condition checker: query a PR field, compare to a trigger value,
# fire a webhook notification once when the trigger first matches, and reset
# the flag when the condition clears so a future re-trigger fires again.
check_pr_condition() {
    local field="$1"         # json field to query, e.g. "mergeable"
    local trigger_val="$2"   # value that triggers alert, e.g. "CONFLICTING"
    local flag_var="$3"      # name of global flag variable, e.g. "REPORTED_CONFLICT"
    local message="$4"       # notification message to send

    local current_val
    current_val=$(gh pr view "$BRANCH" --json "$field" --jq ".$field" 2>/dev/null) || current_val=""
    if [ "$current_val" = "$trigger_val" ]; then
        local flag_state
        flag_state=${!flag_var}
        if [ -z "$flag_state" ]; then
            curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "$message"
            printf -v "$flag_var" "1"
        fi
    else
        printf -v "$flag_var" ""
    fi
}

# Refresh the MERGEABLE global so check_all_passed can suppress the success
# notification while the PR is in a CONFLICTING state.
update_mergeable() {
    MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>/dev/null) || MERGEABLE=""
}

detect_new_sha() {
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r 'max_by(.databaseId).headSha')
    if [ -z "$CURRENT_SHA" ] || [ "$CURRENT_SHA" = "null" ]; then
        return
    fi
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
    echo "$runs_json" | jq --arg sha "$sha" '
      [.[] | select(.headSha == $sha)]
      | group_by(.name)
      | map(sort_by(.databaseId) | last)
    '
}

check_failures() {
    local context="$1"  # "branch" or "main"
    local reported_fail_var="$2"  # name of the reported-fail flag variable

    local failed_runs failed_names failed_ids all_failed_jobs first_failed_id msg
    failed_runs=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$failed_runs" | jq 'length')" -gt 0 ]; then
        failed_names=$(echo "$failed_runs" | jq -r '.[].name' | paste -sd ', ' -)
        failed_ids=$(echo "$failed_runs" | jq -r '.[].databaseId')

        all_failed_jobs=""
        while IFS= read -r RUN_ID; do
            local failed_jobs
            failed_jobs=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null || true)
            if [ -n "$failed_jobs" ]; then
                all_failed_jobs="${all_failed_jobs}${failed_jobs} "
            fi
        done <<< "$failed_ids"

        first_failed_id=$(echo "$failed_runs" | jq -r '.[0].databaseId')

        if [ "$context" = "main" ]; then
            msg="CI on $DEFAULT_BRANCH failed for merge of '$BRANCH' (workflows: $failed_names)."
        else
            msg="CI failed on branch '$BRANCH' (workflows: $failed_names)."
        fi
        if [ -n "$all_failed_jobs" ]; then
            msg="${msg} Failed jobs: ${all_failed_jobs}"
        fi
        msg="${msg} Run 'gh run view $first_failed_id --log-failed' to get the logs."
        if [ "$context" = "branch" ]; then
            msg="${msg} Delegate the fix to coder-agent."
        fi

        local current_val
        current_val=${!reported_fail_var}
        if [ -z "$current_val" ]; then
            if [ "$context" = "main" ]; then
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "CI FAILURE on $DEFAULT_BRANCH for merge of $BRANCH: $msg"
            else
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "CI FAILURE on branch $BRANCH: $msg"
            fi
            printf -v "$reported_fail_var" "1"
        fi
    fi
}

check_all_passed() {
    local context="$1"  # "branch" or "main"
    local reported_pass_var="$2"  # name of the reported-pass flag variable

    [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ] && return
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed" or .conclusion != "success")] | length')" -eq 0 ]; then
        local current_val
        current_val=${!reported_pass_var}
        if [ -z "$current_val" ]; then
            if [ "$context" = "main" ]; then
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "✅ CI on $DEFAULT_BRANCH passed for merge of $BRANCH"
                printf -v "$reported_pass_var" "1"
            elif [ "$MERGEABLE" != "CONFLICTING" ]; then
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "✅ CI passed on branch $BRANCH"
                printf -v "$reported_pass_var" "1"
            fi
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

# --- Main loop ---

while true; do

    # --- Session health check ---
    HEALTH=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null) || HEALTH=""
    if [ "$HEALTH" != "ok:$SESSION_TOKEN" ]; then
        echo "Session token mismatch or unreachable (expected ok:$SESSION_TOKEN, got '$HEALTH'). Exiting."
        exit 0
    fi

    # --- Check if PR was merged ---
    if [ -z "$MERGED" ]; then
        check_merged
    fi

    # --- Merged path: track main CI for the merge commit ---
    if [ -n "$MERGED" ]; then
        MAIN_RUNS_JSON=$(fetch_runs_for "$DEFAULT_BRANCH")
        SHA_RUNS=$(get_sha_runs_for "$MAIN_RUNS_JSON" "$MERGE_COMMIT_SHA")

        if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
            # Only start counting the timeout after the merge commit is actually
            # visible on the default branch. Until then, the commit may simply
            # not have propagated yet (GitHub eventual consistency), so a
            # counter increment here could cause a premature 5-min timeout.
            # We check commit visibility via `gh api` — if it fails, reset the
            # counter and keep polling.
            if gh api "repos/{owner}/{repo}/commits/$MERGE_COMMIT_SHA" --jq '.sha' >/dev/null 2>&1; then
                MAIN_WAIT_ITERATIONS=$((MAIN_WAIT_ITERATIONS + 1))
                if [ "$MAIN_WAIT_ITERATIONS" -ge "$MAIN_WAIT_MAX" ]; then
                    curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "⚠️ No CI runs found on $DEFAULT_BRANCH for merge commit of $BRANCH after $((MAIN_WAIT_MAX * POLL_INTERVAL))s. Check manually."
                    echo "Timed out waiting for main CI runs. Exiting."
                    exit 0
                fi
            else
                # Merge commit not yet visible on default branch — don't count.
                MAIN_WAIT_ITERATIONS=0
            fi
            sleep "$POLL_INTERVAL"
            continue
        fi

        MAIN_WAIT_ITERATIONS=0
        check_failures "main" REPORTED_MAIN_FAIL
        check_all_passed "main" REPORTED_MAIN_PASS

        if [ -n "$REPORTED_MAIN_PASS" ] || [ -n "$REPORTED_MAIN_FAIL" ]; then
            echo "Main CI resolved for merge of '$BRANCH'. Exiting."
            exit 0
        fi

        sleep "$POLL_INTERVAL"
        continue
    fi

    # --- Branch tracking path (existing logic) ---
    RUNS_JSON=$(fetch_runs_for "$BRANCH")

    check_pr_condition "mergeable" "CONFLICTING" "REPORTED_CONFLICT" "CI FAILURE on branch $BRANCH: PR has merge conflicts. Delegate the fix to coder-agent."
    update_mergeable
    check_pr_condition "mergeStateStatus" "BEHIND" "REPORTED_BEHIND" "CI FAILURE on branch $BRANCH: PR is behind the base branch and needs to be updated. Run /sync to update the branch."

    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    detect_new_sha

    SHA_RUNS=$(get_sha_runs_for "$RUNS_JSON" "$LATEST_SHA")

    if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    check_failures "branch" REPORTED_FAIL
    check_all_passed "branch" REPORTED_PASS

    sleep "$POLL_INTERVAL"
done
