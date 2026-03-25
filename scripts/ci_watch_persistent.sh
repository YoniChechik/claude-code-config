#!/usr/bin/env bash
# Polls GitHub Actions CI status after a push and reports results to the orchestrator.
# Designed for the exit-and-relaunch pattern: exits on every terminal event with
# descriptive output telling the orchestrator what to do next.
# Exit code: 0 = CI passed, newer push, or no workflows. 1 = CI failed, merge conflict, or timeout.
set -euo pipefail

BRANCH="${1:?Usage: ci_watch_persistent.sh <branch>}"

POLL_INTERVAL=5
MAX_TIMEOUT=600
MAX_ITERATIONS=$((MAX_TIMEOUT / POLL_INTERVAL))

# Resolve branch to SHA so concurrent watchers on different branches each track their own commit.
LATEST_SHA=$(git rev-parse "$BRANCH")

RELAUNCH_CMD="\$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH"

for ((num_iter = 0; num_iter < MAX_ITERATIONS; num_iter++)); do
    RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)

    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        # After 3 polls (~15s) with no workflows, assume the repo has none configured.
        if [ "$num_iter" -ge 3 ]; then
            # Still check for merge conflicts even without CI workflows
            MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
            if [ "$MERGEABLE" = "CONFLICTING" ]; then
                echo "PR on branch '$BRANCH' has merge conflicts. Delegate conflict resolution to coder-agent, then relaunch this watcher with: \`$RELAUNCH_CMD\`"
                exit 1
            fi
            echo "No CI workflows found for branch '$BRANCH'."
            exit 0
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Check for merge conflicts
    MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
    if [ "$MERGEABLE" = "CONFLICTING" ]; then
        echo "PR on branch '$BRANCH' has merge conflicts. Delegate conflict resolution to coder-agent, then relaunch this watcher with: \`$RELAUNCH_CMD\`"
        exit 1
    fi

    # If the latest run's SHA differs from ours, a newer push happened — let its watcher take over.
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
        echo "Newer push detected on branch '$BRANCH'. This watcher is superseded — exiting cleanly."
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
        sleep "$POLL_INTERVAL"
        continue
    fi

    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
        break
    fi

    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
        echo "CI passed on branch '$BRANCH'. All workflows green."
        exit 0
    fi

    sleep "$POLL_INTERVAL"

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
    MSG="${MSG} Delegate fix to coder-agent: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs, fix the issue, commit, and push. Then relaunch this watcher with: \`$RELAUNCH_CMD\`"
    echo "$MSG"
    exit 1
fi

echo "CI monitoring timed out after $((MAX_TIMEOUT / 60)) minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'. You may relaunch this watcher with: \`$RELAUNCH_CMD\`"
exit 1
