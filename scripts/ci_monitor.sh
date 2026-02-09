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

MAX_ITERATIONS=40
for ((i = 0; i < MAX_ITERATIONS; i++)); do
    RUN_JSON=$(gh run list --branch "$BRANCH" --limit 1 --json databaseId,status,conclusion,name)

    RUN_ID=$(echo "$RUN_JSON" | jq -r '.[0].databaseId')
    STATUS=$(echo "$RUN_JSON" | jq -r '.[0].status')
    CONCLUSION=$(echo "$RUN_JSON" | jq -r '.[0].conclusion')
    WORKFLOW_NAME=$(echo "$RUN_JSON" | jq -r '.[0].name')

    if [ "$RUN_ID" = "null" ] || [ -z "$RUN_ID" ]; then
        sleep 15
        continue
    fi

    TIMESTAMP=$(date +%s)

    if [ "$STATUS" = "completed" ]; then
        if [ "$CONCLUSION" = "success" ]; then
            echo "pass|$TIMESTAMP" > "$CACHE_FILE"
            exit 0
        else
            echo "fail|$TIMESTAMP" > "$CACHE_FILE"
            FAILED_JOBS=$(gh run view "$RUN_ID" --json jobs -q '.jobs[] | select(.conclusion=="failure") | .name')
            echo "CI failed on branch '$BRANCH' (workflow: $WORKFLOW_NAME)" >&2
            echo "Failed jobs:" >&2
            echo "$FAILED_JOBS" >&2
            echo "View logs: gh run view $RUN_ID --log-failed" >&2
            exit 1
        fi
    fi

    echo "running|$TIMESTAMP" > "$CACHE_FILE"
    sleep 15
done

TIMESTAMP=$(date +%s)
echo "fail|$TIMESTAMP" > "$CACHE_FILE"
echo "CI monitoring timed out after 10 minutes on branch '$BRANCH'" >&2
exit 1
