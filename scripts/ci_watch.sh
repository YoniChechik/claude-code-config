#!/usr/bin/env bash
set -euo pipefail

BRANCH="${1:?Usage: ci_watch.sh <branch>}"

sleep 5

FOUND_RUN=false
LATEST_SHA=""
MAX_ITERATIONS=40
for ((i = 0; i < MAX_ITERATIONS; i++)); do
    RUNS_JSON=$(gh run list --branch "$BRANCH" --limit 10 --json databaseId,status,conclusion,name,headSha)

    RUN_COUNT=$(echo "$RUNS_JSON" | jq 'length')
    if [ "$RUN_COUNT" = "0" ]; then
        sleep 15
        continue
    fi

    # On first detection, lock onto the latest headSha
    if [ -z "$LATEST_SHA" ]; then
        LATEST_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    fi

    # Filter to only runs matching the latest push's SHA
    SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '[.[] | select(.headSha == $sha)]')

    SHA_RUN_COUNT=$(echo "$SHA_RUNS" | jq 'length')
    if [ "$SHA_RUN_COUNT" = "0" ]; then
        sleep 15
        continue
    fi

    FOUND_RUN=true

    # Check how many are still in progress
    PENDING_COUNT=$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')

    if [ "$PENDING_COUNT" -gt 0 ]; then
        sleep 15
        continue
    fi

    # All runs completed - check conclusions
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.conclusion != "success")]')
    FAILED_COUNT=$(echo "$FAILED_RUNS" | jq 'length')

    if [ "$FAILED_COUNT" -eq 0 ]; then
        echo "CI passed on branch '$BRANCH'. All workflows green."
        exit 0
    fi

    # At least one workflow failed
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

if [ "$FOUND_RUN" = false ]; then
    echo "No CI workflows found for branch '$BRANCH'."
    exit 0
fi

echo "CI monitoring timed out after 10 minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'."
exit 1
