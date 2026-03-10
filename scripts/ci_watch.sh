#!/usr/bin/env bash
# Polls GitHub Actions CI status after a push and reports results to Claude.
# Exit code: 0 = CI passed or no workflows, 1 = CI failed or timed out.
set -euo pipefail

BRANCH="${1:?Usage: ci_watch.sh <branch>}"

POLL_INTERVAL=5
MAX_TIMEOUT=600
MAX_ITERATIONS=$((MAX_TIMEOUT / POLL_INTERVAL))

# Resolve branch to SHA so concurrent watchers on different branches each track their own commit.
LATEST_SHA=$(git rev-parse "$BRANCH")

# Check if PR has merge conflicts. Returns 1 if conflicts detected, 0 otherwise.
# Sets CONFLICT_MSG variable if conflicts found.
check_merge_conflicts() {
    CONFLICT_MSG=""
    local max_retries=5
    for ((retry = 0; retry < max_retries; retry++)); do
        local pr_json
        pr_json=$(gh pr view "$BRANCH" --json mergeable,mergeStateStatus 2>/dev/null) || return 0
        local mergeable
        mergeable=$(echo "$pr_json" | jq -r '.mergeable')
        if [ "$mergeable" = "CONFLICTING" ]; then
            CONFLICT_MSG="PR on branch '$BRANCH' has merge conflicts. You MUST resolve the merge conflicts now before continuing."
            return 1
        elif [ "$mergeable" = "UNKNOWN" ]; then
            sleep $POLL_INTERVAL
            continue
        else
            return 0
        fi
    done
    # After max retries with UNKNOWN, treat as no conflict
    return 0
}

for ((num_iter = 0; num_iter < MAX_ITERATIONS; num_iter++)); do
    RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)

    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        # After 3 polls (~15s) with no workflows, assume the repo has none configured.
        if [ "$num_iter" -ge 3 ]; then
            if ! check_merge_conflicts; then
                echo "$CONFLICT_MSG"
                exit 1
            fi
            echo "No CI workflows found for branch '$BRANCH'."
            exit 0
        fi
        sleep $POLL_INTERVAL
        continue
    fi

    # If the latest run's SHA differs from ours, a newer push happened — let its watcher take over.
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
        echo "Newer push detected on branch '$BRANCH'. Exiting — new watcher will handle it."
        exit 0
    fi

    # Filter to our commit's runs, then deduplicate: group by workflow name and keep only the
    # latest run (highest databaseId) per workflow — re-runs shouldn't show stale results.
    SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '
      [.[] | select(.headSha == $sha)]
      | group_by(.name)
      | map(sort_by(.databaseId) | last)
    ')

    # GitHub may not have registered runs for our commit yet — keep polling.
    if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
        break
    fi

    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
        if ! check_merge_conflicts; then
            echo "$CONFLICT_MSG"
            exit 1
        fi
        echo "CI passed on branch '$BRANCH'. All workflows green."
        exit 0
    fi

    sleep $POLL_INTERVAL
    continue

done

# Post-loop: we get here on failure (break) or timeout (loop exhausted).
# Report failed workflows with their job names and actionable log command.
if [ -n "${FAILED_RUNS:-}" ] && [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
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
    MSG="${MSG} You MUST fix this now: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs, then use coder-agent to fix the issue, commit, and push."
    if ! check_merge_conflicts; then
        MSG="${MSG} Additionally, ${CONFLICT_MSG}"
    fi
    echo "$MSG"
    exit 1
fi

if ! check_merge_conflicts; then
    echo "CI monitoring timed out after $((MAX_TIMEOUT / 60)) minutes on branch '$BRANCH'. ${CONFLICT_MSG}"
    exit 1
fi
echo "CI monitoring timed out after $((MAX_TIMEOUT / 60)) minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'."
exit 1
