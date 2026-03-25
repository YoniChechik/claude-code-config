#!/usr/bin/env bash
#
# Persistent CI Watcher
# =====================
# Monitors GitHub Actions CI status for a branch and reports results.
#
# Architecture:
#   The script uses a nested loop pattern:
#   - OUTER LOOP (while true): each iteration handles one push cycle.
#     1. Inner CI-polling loop: polls CI status for the current commit SHA.
#     2. Post-loop: reports the CI result (pass/fail/timeout/conflict).
#     3. Wait-for-new-SHA loop: idles until a new push is detected.
#
#   The watcher is "persistent" -- it never exits after reporting a CI result.
#   Instead, it resets and waits for the next push. This means the caller only
#   needs to launch it once and it will track all subsequent pushes.
#
# Exit conditions (the ONLY ways the script terminates):
#   - No branch argument provided (exit 1)
#   - No CI workflows found for the branch after several polls (exit 0)
#   - Inactivity timeout: no new pushes for INACTIVITY_TIMEOUT seconds (exit 0)
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
set -euo pipefail

# --- Configuration ---
BRANCH="${1:?Usage: ci_watch_persistent.sh <branch>}"

POLL_INTERVAL=5
CI_RUN_TIMEOUT=600
CI_RUN_MAX_ITERATIONS=$((CI_RUN_TIMEOUT / POLL_INTERVAL))
# If no new push happens within this window, the watcher exits cleanly.
INACTIVITY_TIMEOUT=1800  # 30 minutes

# Resolve branch to its current commit SHA.
LATEST_SHA=$(git rev-parse "$BRANCH")
# Timestamp of last meaningful activity (push detection or startup).
# Used by the inactivity timeout mechanism.
LAST_ACTIVITY_TIME=$(date +%s)

# =============================================================================
# OUTER LOOP: one iteration per push cycle (CI poll -> report -> wait for push)
# =============================================================================
while true; do
    # ---- Inner loop: poll CI status for the current SHA ----
    # Tracks whether any workflow failed and which ones.
    FOUND_FAILURE=""
    FAILED_RUNS=""
    TIMED_OUT=""

    # Poll up to CI_RUN_MAX_ITERATIONS times, sleeping POLL_INTERVAL between polls.
    for ((num_iter = 0; num_iter < CI_RUN_MAX_ITERATIONS; num_iter++)); do
        # Fetch all CI runs for this branch (any SHA) as JSON.
        RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)

        # --- Handle "no workflows" edge case ---
        if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
            # After 3 polls (~15s) with zero runs, assume the repo has no CI configured.
            # We wait a few polls because GitHub may take a moment to register new runs.
            if [ "$num_iter" -ge 3 ]; then
                # Even without CI, check for merge conflicts on the PR.
                MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
                if [ "$MERGEABLE" = "CONFLICTING" ]; then
                    echo "PR on branch '$BRANCH' has merge conflicts. Fix the conflicts, commit, and push. This watcher will automatically track the new CI run."
                    LAST_ACTIVITY_TIME=$(date +%s)
                    break  # Exit inner loop -> go to wait-for-new-SHA
                fi
                echo "No CI workflows found for branch '$BRANCH'."
                exit 0
            fi
            sleep "$POLL_INTERVAL"
            continue
        fi

        # --- Check for merge conflicts on the PR ---
        # Uses `|| MERGEABLE=""` so a missing PR (gh exits non-zero) doesn't abort the script.
        MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
        if [ "$MERGEABLE" = "CONFLICTING" ]; then
            echo "PR on branch '$BRANCH' has merge conflicts. Fix the conflicts, commit, and push. This watcher will automatically track the new CI run."
            LAST_ACTIVITY_TIME=$(date +%s)
            break  # Exit inner loop -> go to wait-for-new-SHA
        fi

        # --- Detect new pushes mid-poll ---
        # If the latest run's SHA differs from ours, someone pushed a new commit.
        # Update our tracked SHA and reset the inactivity timer.
        CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
        if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
            echo "New push detected on branch '$BRANCH' (new SHA: $CURRENT_SHA). Now tracking new CI run."
            LATEST_SHA="$CURRENT_SHA"
            LAST_ACTIVITY_TIME=$(date +%s)
        fi

        # --- Filter and deduplicate runs for our SHA ---
        # 1. Select only runs matching our tracked SHA.
        # 2. Group by workflow name and keep only the run with the highest databaseId
        #    per group. This ensures re-runs of the same workflow don't show stale results.
        SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '
          [.[] | select(.headSha == $sha)]
          | group_by(.name)
          | map(sort_by(.databaseId) | last)
        ')

        # GitHub may not have registered runs for our SHA yet -- keep polling.
        if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        # --- Check for failures ---
        FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
        if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
            FOUND_FAILURE=1
            break
        fi

        # --- Check if all runs completed successfully ---
        # If no runs are still in progress/queued, everything passed.
        if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
            echo "CI passed on branch '$BRANCH'. All workflows green."
            break  # Exit inner loop -> go to wait-for-new-SHA
        fi

        sleep "$POLL_INTERVAL"
    done

    # Check if the inner loop exhausted all iterations (timeout).
    if [ "$num_iter" -ge "$CI_RUN_MAX_ITERATIONS" ]; then
        TIMED_OUT=1
    fi

    # =========================================================================
    # Post-inner-loop: report CI failure or timeout
    # =========================================================================
    if [ -n "$FOUND_FAILURE" ] && [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
        # Build a human-readable failure report with workflow names and failed job names.
        FAILED_NAMES=$(echo "$FAILED_RUNS" | jq -r '.[].name' | paste -sd ', ' -)
        FAILED_IDS=$(echo "$FAILED_RUNS" | jq -r '.[].databaseId')

        # For each failed run, query GitHub for the specific failed job names.
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
    elif [ -n "$TIMED_OUT" ]; then
        # Inner loop exhausted all iterations without all runs completing.
        echo "CI run timed out after $((CI_RUN_TIMEOUT / 60)) minutes on branch '$BRANCH'. This watcher will automatically track the next CI run when you push."
    fi

    # =========================================================================
    # Wait-for-new-SHA loop: idle until a new push is detected or timeout
    # =========================================================================
    echo "Waiting for new push on branch '$BRANCH'..."
    while true; do
        # --- Inactivity timeout check ---
        # If no new push has been detected for INACTIVITY_TIMEOUT seconds, exit cleanly.
        NOW=$(date +%s)
        ELAPSED=$(( NOW - LAST_ACTIVITY_TIME ))
        if [ "$ELAPSED" -ge "$INACTIVITY_TIMEOUT" ]; then
            echo "No new pushes detected for $((INACTIVITY_TIMEOUT / 60)) minutes. Exiting watcher."
            exit 0
        fi

        # --- Poll for new SHA via GitHub API ---
        # We check GitHub's run list rather than `git rev-parse` because the local
        # repo may not have fetched the latest commits. GitHub's API is the
        # authoritative source for what SHA is being built.
        NEW_SHA=$(gh run list --branch "$BRANCH" --json headSha --jq '.[0].headSha' 2>/dev/null || echo "$LATEST_SHA")

        if [ "$NEW_SHA" != "$LATEST_SHA" ]; then
            echo "New push detected on branch '$BRANCH' (new SHA: $NEW_SHA). Now tracking new CI run."
            LATEST_SHA="$NEW_SHA"
            LAST_ACTIVITY_TIME=$(date +%s)
            break  # Exit wait loop -> restart outer loop for new CI polling cycle
        fi

        sleep "$POLL_INTERVAL"
    done
done
