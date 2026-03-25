#!/usr/bin/env bash
# Persistent CI watcher: polls GitHub Actions CI status after a push and reports results.
# Never exits after reporting a CI result — resets and waits for a new push (SHA change).
# The ONLY exit conditions: no branch arg, no CI workflows, no PR, or inactivity timeout.
# Exit code: 0 = clean exit (no workflows / inactivity timeout). 1 = no branch arg.
set -euo pipefail

BRANCH="${1:?Usage: ci_watch_persistent.sh <branch>}"

POLL_INTERVAL=5
CI_RUN_TIMEOUT=600
CI_RUN_MAX_ITERATIONS=$((CI_RUN_TIMEOUT / POLL_INTERVAL))
INACTIVITY_TIMEOUT=1800  # 30 minutes

# Resolve branch to SHA so we track the right commit.
LATEST_SHA=$(git rev-parse "$BRANCH")
LAST_ACTIVITY_TIME=$(date +%s)

while true; do
    # ---- Inner loop: track one CI run for the current SHA ----
    FOUND_FAILURE=""
    FAILED_RUNS=""

    for ((num_iter = 0; num_iter < CI_RUN_MAX_ITERATIONS; num_iter++)); do
        RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)

        if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
            # After 3 polls (~15s) with no workflows, assume the repo has none configured.
            if [ "$num_iter" -ge 3 ]; then
                # Still check for merge conflicts even without CI workflows
                MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
                if [ "$MERGEABLE" = "CONFLICTING" ]; then
                    echo "PR on branch '$BRANCH' has merge conflicts. Fix the conflicts, commit, and push. This watcher will automatically track the new CI run."
                    break  # Break inner loop, go to wait-for-new-SHA
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
            echo "PR on branch '$BRANCH' has merge conflicts. Fix the conflicts, commit, and push. This watcher will automatically track the new CI run."
            break  # Break inner loop, go to wait-for-new-SHA
        fi

        # If the latest run's SHA differs from ours, a newer push happened — update tracked SHA and restart inner loop.
        CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
        if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
            echo "New push detected on branch '$BRANCH' (new SHA: $CURRENT_SHA). Now tracking new CI run."
            LATEST_SHA="$CURRENT_SHA"
            LAST_ACTIVITY_TIME=$(date +%s)
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
            FOUND_FAILURE=1
            break
        fi

        if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
            echo "CI passed on branch '$BRANCH'. All workflows green."
            break  # Break inner loop, go to wait-for-new-SHA
        fi

        sleep "$POLL_INTERVAL"
    done

    # Post-inner-loop: report failure or timeout if applicable
    if [ -n "$FOUND_FAILURE" ] && [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
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
        MSG="${MSG} Delegate fix to coder-agent: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs. Fix the issues and push. This watcher will automatically track the new CI run."
        echo "$MSG"
    elif [ "$num_iter" -ge "$CI_RUN_MAX_ITERATIONS" ]; then
        echo "CI run timed out after $((CI_RUN_TIMEOUT / 60)) minutes on branch '$BRANCH'. This watcher will automatically track the next CI run when you push."
    fi

    # ---- Wait for a new SHA (new push) ----
    echo "Waiting for new push on branch '$BRANCH'..."
    while true; do
        NOW=$(date +%s)
        ELAPSED=$(( NOW - LAST_ACTIVITY_TIME ))
        if [ "$ELAPSED" -ge "$INACTIVITY_TIMEOUT" ]; then
            echo "No new pushes detected for $((INACTIVITY_TIMEOUT / 60)) minutes. Exiting watcher."
            exit 0
        fi

        # Check GitHub CI runs for a newer SHA — this is the authoritative source.
        # git rev-parse only reflects local state and would need a fetch to update.
        NEW_SHA=$(gh run list --branch "$BRANCH" --json headSha --jq '.[0].headSha' 2>/dev/null || echo "$LATEST_SHA")

        if [ "$NEW_SHA" != "$LATEST_SHA" ]; then
            echo "New push detected on branch '$BRANCH' (new SHA: $NEW_SHA). Now tracking new CI run."
            LATEST_SHA="$NEW_SHA"
            LAST_ACTIVITY_TIME=$(date +%s)
            break  # Break wait loop, restart inner CI tracking loop
        fi

        sleep "$POLL_INTERVAL"
    done
done
