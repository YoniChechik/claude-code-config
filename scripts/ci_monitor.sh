#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Only proceed for git push or gh pr create
if [[ "$COMMAND" != *"git push"* ]] && [[ "$COMMAND" != *"gh pr create"* ]]; then
    exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
CACHE_DIR="$HOME/.claude/ci_status_cache"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/$BRANCH"

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
    TIMESTAMP=$(date +%s)

    # Check how many are still in progress
    PENDING_COUNT=$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')

    if [ "$PENDING_COUNT" -gt 0 ]; then
        echo "running|$TIMESTAMP" > "$CACHE_FILE"
        sleep 15
        continue
    fi

    # All runs completed - check conclusions
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.conclusion != "success")]')
    FAILED_COUNT=$(echo "$FAILED_RUNS" | jq 'length')

    if [ "$FAILED_COUNT" -eq 0 ]; then
        echo "pass|$TIMESTAMP" > "$CACHE_FILE"
        exit 0
    fi

    # At least one workflow failed
    echo "fail|$TIMESTAMP" > "$CACHE_FILE"

    FAILED_NAMES=$(echo "$FAILED_RUNS" | jq -r '.[].name' | paste -sd ', ' -)
    FAILED_IDS=$(echo "$FAILED_RUNS" | jq -r '.[].databaseId')

    ALL_FAILED_JOBS=""
    while IFS= read -r RUN_ID; do
        FAILED_JOBS=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null || true)
        if [ -n "$FAILED_JOBS" ]; then
            ALL_FAILED_JOBS="${ALL_FAILED_JOBS}${FAILED_JOBS}"$'\n'
        fi
    done <<< "$FAILED_IDS"

    echo "ACTION REQUIRED: CI failed on branch '$BRANCH' (workflows: $FAILED_NAMES)." >&2
    if [ -n "$ALL_FAILED_JOBS" ]; then
        echo "Failed jobs:" >&2
        echo "$ALL_FAILED_JOBS" >&2
    fi
    FIRST_FAILED_ID=$(echo "$FAILED_RUNS" | jq -r '.[0].databaseId')
    echo "You MUST fix this now: run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs, then use debugger-agent to fix the issue, commit, and push." >&2
    exit 1
done

if [ "$FOUND_RUN" = false ]; then
    # No CI workflows found for this branch - exit silently
    exit 0
fi

TIMESTAMP=$(date +%s)
echo "fail|$TIMESTAMP" > "$CACHE_FILE"
echo "CI monitoring timed out after 10 minutes on branch '$BRANCH'. Check CI status manually with 'gh run list --branch $BRANCH'." >&2
exit 1
