#!/usr/bin/env bash
# Polls GitHub Actions CI status after a push and reports results to Claude.
# Runs as a background task, triggered by ci_post_push_hook.sh.
# Output (echo) is what Claude sees when checking on the task.
# Exit code: 0 = CI passed or no workflows, 1 = CI failed or timed out.
set -euo pipefail

BRANCH="${1:?Usage: ci_watch.sh <branch>}"

# If repo has never had a CI run, there's no CI configured — exit immediately
if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    echo "No CI workflows configured."
    exit 0
fi

POLL_INTERVAL=5
MAX_TIMEOUT=600
MAX_ITERATIONS=$((MAX_TIMEOUT / POLL_INTERVAL))

LATEST_SHA=""

for ((num_iter = 0; num_iter < MAX_ITERATIONS; num_iter++)); do
    # Fetch all workflow runs for this branch (each workflow = separate run, e.g. "lint", "test", "build")
    RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)

    # GitHub may not have registered the push yet — no runs exist for this branch.
    # After 15s with no runs, assume no CI is configured for this branch and exit.
    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        if [ "$num_iter" -ge 3 ]; then
            echo "No CI workflows found for branch '$BRANCH'."
            exit 0
        fi
        sleep $POLL_INTERVAL
        continue
    fi

    # On first detection, lock onto this SHA (= the push that triggered us)
    if [ -z "$LATEST_SHA" ]; then
        LATEST_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    fi

    # If a newer push happened, a new watcher will handle it — exit this one
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
        echo "Newer push detected on branch '$BRANCH'. Exiting — new watcher will handle it."
        exit 0
    fi

    # Filter to only runs matching our SHA (ignore older runs from previous pushes)
    SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '[.[] | select(.headSha == $sha)]')

    # Some workflows still running (status: queued/in_progress) — wait for all to finish
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -gt 0 ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    # === All runs completed — evaluate results ===

    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.conclusion != "success")]')

    # All green
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -eq 0 ]; then
        echo "CI passed on branch '$BRANCH'. All workflows green."
        exit 0
    fi

    # At least one workflow failed — collect details for Claude's error message.
    # For each failed workflow run, fetch its individual failed job names
    # (a workflow can have multiple jobs, we want the specific ones that failed).
    FAILED_NAMES=$(echo "$FAILED_RUNS" | jq -r '.[].name' | paste -sd ', ' -)
    FAILED_IDS=$(echo "$FAILED_RUNS" | jq -r '.[].databaseId')

    ALL_FAILED_JOBS=""
    while IFS= read -r RUN_ID; do
        FAILED_JOBS=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null || true)
        if [ -n "$FAILED_JOBS" ]; then
            ALL_FAILED_JOBS="${ALL_FAILED_JOBS}${FAILED_JOBS}"$'\n'
        fi
    done <<< "$FAILED_IDS"

    # Build the error message with workflow names, failed job names, and a command to view logs
    FIRST_FAILED_ID=$(echo "$FAILED_RUNS" | jq -r '.[0].databaseId')
    MSG="CI failed on branch '$BRANCH' (workflows: $FAILED_NAMES)."
    if [ -n "$ALL_FAILED_JOBS" ]; then
        MSG="${MSG} Failed jobs: ${ALL_FAILED_JOBS}"
    fi
    MSG="${MSG} You MUST fix this now: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs, then use debugger-agent to fix the issue, commit, and push."
    echo "$MSG"
    exit 1
done

# Loop exhausted without resolving
echo "CI monitoring timed out after $((MAX_TIMEOUT / 60)) minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'."
exit 1
