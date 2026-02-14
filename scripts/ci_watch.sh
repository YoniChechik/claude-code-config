#!/usr/bin/env bash
# Polls GitHub Actions CI status after a push and reports results to Claude.
# Runs as a background task, triggered by ci_post_push_hook.sh.
# Output (echo) is what Claude sees when checking on the task.
# Exit code: 0 = CI passed or no workflows, 1 = CI failed or timed out.
set -euo pipefail

BRANCH="${1:?Usage: ci_watch.sh <branch>}"

# Quick check: if repo has no CI runs at all, exit immediately
if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    echo "No CI workflows configured."
    exit 0
fi

# Wait for GitHub to register the push and trigger workflows
sleep 5

POLL_INTERVAL=15
MAX_TIMEOUT=600
MAX_ITERATIONS=$((MAX_TIMEOUT / POLL_INTERVAL))

LATEST_SHA=""

for ((i = 0; i < MAX_ITERATIONS; i++)); do
    RUNS_JSON=$(gh run list --branch "$BRANCH" --limit 10 --json databaseId,status,conclusion,name,headSha)

    # No workflows yet — keep waiting
    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    # Lock onto the SHA from the first detected run (= the push that triggered us)
    if [ -z "$LATEST_SHA" ]; then
        LATEST_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    fi

    # Only look at runs for our specific push
    SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '[.[] | select(.headSha == $sha)]')
    if [ "$(echo "$SHA_RUNS" | jq 'length')" = "0" ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    # Still running — keep polling
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -gt 0 ]; then
        sleep $POLL_INTERVAL
        continue
    fi

    # All runs completed — check for failures
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.conclusion != "success")]')

    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -eq 0 ]; then
        echo "CI passed on branch '$BRANCH'. All workflows green."
        exit 0
    fi

    # Collect failure details for Claude's error message
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
    MSG="${MSG} You MUST fix this now: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs, then use debugger-agent to fix the issue, commit, and push."
    echo "$MSG"
    exit 1
done

# Loop exhausted without resolving
echo "CI monitoring timed out after $((MAX_TIMEOUT / 60)) minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'."
exit 1
