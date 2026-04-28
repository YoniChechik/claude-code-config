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
PORT="${1:?Usage: ci_watch_persistent.sh <port> <branch> <session_token> <sid8>}"
BRANCH="${2:?Usage: ci_watch_persistent.sh <port> <branch> <session_token> <sid8>}"
SESSION_TOKEN="${3:?Usage: ci_watch_persistent.sh <port> <branch> <session_token> <sid8>}"
# Sanitize branch name for use in /tmp file paths: branches like "feature/foo"
# would otherwise produce paths like /tmp/ci_watch_state_feature/foo which fail
# because the parent dir doesn't exist. Replace "/" with "__".
BRANCH_KEY="${BRANCH//\//__}"
# 8-char session id (passed by /ci skill). Combined with BRANCH_KEY into SLOT
# so each Claude Code window gets its own /tmp state files even when watching
# the same branch from multiple windows.
SID8="${4:-unknown}"
SLOT="${BRANCH_KEY}_${SID8}"
POLL_INTERVAL=5
LATEST_SHA=$(gh api "repos/{owner}/{repo}/commits/$BRANCH" --jq '.sha' 2>/dev/null) || {
    echo "Error: could not resolve branch '$BRANCH' to a SHA. Does the branch exist on the remote?" >&2
    exit 1
}
# Validate we actually got a SHA (not an empty string from a silent gh failure)
if [ -z "$LATEST_SHA" ]; then
    echo "Error: resolved SHA is empty for branch '$BRANCH'. Does the branch exist on the remote?" >&2
    exit 1
fi

# Clean up the state file on any exit (BRANCH is now defined),
# unless KEEP_STATE_FILE=1 (set before intentional exits where we want to
# preserve the final state for the statusline to display).
KEEP_STATE_FILE=""
LOCK_FILE="/tmp/ci_watch_lock_${SLOT}"
trap '[[ -z "$KEEP_STATE_FILE" ]] && rm -f "/tmp/ci_watch_state_${SLOT}" "/tmp/ci_watch_pr_${SLOT}"; rm -f "$LOCK_FILE"' EXIT

# Prevent multiple watchers for the same branch — kill any stale predecessor.
if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Validate it's actually our watcher before killing.
        if ps -p "$OLD_PID" -o args= 2>/dev/null | grep -q "ci_watch_persistent"; then
            kill "$OLD_PID" 2>/dev/null || true
            # Poll until it exits (max 10 x 1s ticks per CLAUDE.md rules).
            for _i in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$OLD_PID" 2>/dev/null || break
                sleep 1
            done
        fi
    fi
fi
echo $$ > "$LOCK_FILE"

# Atomic state-file writer. Avoids partial reads by status_line.sh racing with us.
write_state() {
    local value="$1"
    local _tmp
    _tmp=$(mktemp "/tmp/ci_watch_state_${SLOT}.XXXXXX")
    printf '%s' "$value" > "$_tmp"
    mv -f "$_tmp" "/tmp/ci_watch_state_${SLOT}"
}

# Initial state: watcher started, CI in progress.
write_state "running"
REPORTED_PASS=""
REPORTED_FAIL=""
REPORTED_CONFLICT=""
REPORTED_BEHIND=""
RUNS_JSON=""
SHA_RUNS=""
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || DEFAULT_BRANCH="main"
if [ -z "$DEFAULT_BRANCH" ]; then DEFAULT_BRANCH="main"; fi
MERGED=""
MERGE_COMMIT_SHA=""
MAIN_RUNS_JSON=""
MERGEABLE=""
REPORTED_MAIN_PASS=""
REPORTED_MAIN_FAIL=""
MAIN_WAIT_ITERATIONS=0
MAIN_WAIT_MAX=60  # 60 * 5s = 5 minutes
SHA_RUNS_EMPTY_COUNT=0
SHA_RUNS_EMPTY_MAX=24   # ~2 min at 5s poll interval
REPORTED_NO_RUNS=false

# --- Functions ---

fetch_runs_for() {
    local branch="$1"
    local output
    # Fetch up to 100 runs to avoid missing workflows when a branch has many
    # runs (re-runs, many workflows). The default of 20 can cause SHA_RUNS to
    # appear complete when older runs for the current SHA are beyond the cutoff.
    #
    # IMPORTANT: under `set -e`, the pattern `output=$(cmd); exit_code=$?` is
    # broken — set -e aborts the script on the failed assignment before $? can
    # ever be captured. Wrapping in `if ! output=$(cmd); then ...` suppresses
    # set -e for that one assignment AND keeps the exit code observable via $?.
    # On failure, emit an empty JSON array and let the caller retry next iter.
    if ! output=$(gh run list --branch "$branch" --limit 100 --json databaseId,status,conclusion,name,headSha 2>&1); then
        printf '[warn] fetch_runs_for: gh run list failed (exit %d): %s\n' "$?" "$output" >&2
        echo "[]"
        return 0
    fi
    # Validate output is actually JSON (GitHub can return HTML during maintenance).
    if ! printf '%s' "$output" | jq empty 2>/dev/null; then
        printf '[warn] fetch_runs_for: gh returned non-JSON output\n' >&2
        echo "[]"
        return 0
    fi
    echo "$output"
}

# Generic PR-condition checker: compare a pre-fetched PR field value to a trigger value,
# fire a webhook notification once when the trigger first matches, and reset
# the flag when the condition clears so a future re-trigger fires again.
check_pr_condition() {
    local current_val="$1"       # pre-fetched field value, e.g. "CONFLICTING"
    local trigger_val="$2"       # value that triggers alert, e.g. "CONFLICTING"
    local flag_var="$3"          # name of global flag variable, e.g. "REPORTED_CONFLICT"
    local message="$4"           # notification message to send
    local state_on_trigger="$5"  # state string to write on trigger, e.g. "conflict"

    if [ "$current_val" = "$trigger_val" ]; then
        local flag_state
        flag_state=${!flag_var}
        if [ -z "$flag_state" ]; then
            curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "$message"
            printf -v "$flag_var" "1"
            write_state "$state_on_trigger"
        fi
    else
        if [ -n "$current_val" ]; then
            printf -v "$flag_var" ""
        fi
    fi
}

detect_new_sha() {
    [[ -z "$RUNS_JSON" ]] && RUNS_JSON='[]'
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
        SHA_RUNS_EMPTY_COUNT=0
        REPORTED_NO_RUNS=false
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
    [[ -z "$SHA_RUNS" ]] && SHA_RUNS='[]'
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
                write_state "merged-failed"
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "CI FAILURE on $DEFAULT_BRANCH for merge of $BRANCH: $msg"
            else
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "CI FAILURE on branch $BRANCH: $msg"
                write_state "failed"
            fi
            printf -v "$reported_fail_var" "1"
        fi
    fi
}

check_all_passed() {
    local context="$1"  # "branch" or "main"
    local reported_pass_var="$2"  # name of the reported-pass flag variable

    [[ -z "$SHA_RUNS" ]] && SHA_RUNS='[]'
    [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ] && return
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed" or .conclusion != "success")] | length')" -eq 0 ]; then
        local current_val
        current_val=${!reported_pass_var}
        if [ -z "$current_val" ]; then
            if [ "$context" = "main" ]; then
                write_state "merged-passed"
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "✅ CI on $DEFAULT_BRANCH passed for merge of $BRANCH"
                printf -v "$reported_pass_var" "1"
            elif [ "$MERGEABLE" != "CONFLICTING" ]; then
                # Guard against false-positive passes: gh run list only surfaces runs
                # that have already been created on GitHub. Workflows that are still
                # queued or haven't been dispatched yet won't appear in SHA_RUNS, so
                # SHA_RUNS can look "all passed" while checks are still pending.
                # Cross-check with gh pr checks, which includes every check suite
                # entry (including queued ones), before firing the pass notification.
                local pr_checks_json pending_count
                pr_checks_json=$(gh pr checks "$BRANCH" --json bucket 2>/dev/null) || pr_checks_json="[]"
                pending_count=$(echo "$pr_checks_json" | jq '[.[] | select(.bucket == "pending")] | length')
                if [ "$pending_count" -gt 0 ]; then
                    # Some checks are still pending — not all done yet, keep waiting.
                    return
                fi
                curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "✅ CI passed on branch $BRANCH"
                printf -v "$reported_pass_var" "1"
                write_state "passed"
            fi
        fi
    fi
}

check_merged() {
    local pr_state="$1"
    local merge_commit_oid="$2"
    if [ "$pr_state" = "MERGED" ] && [ -n "$merge_commit_oid" ]; then
        MERGED=1
        MERGE_COMMIT_SHA="$merge_commit_oid"
        write_state "merging"
        echo "PR for branch '$BRANCH' has been merged (merge commit: $MERGE_COMMIT_SHA). Now tracking CI on $DEFAULT_BRANCH."
    fi
}

# --- Main loop ---

while true; do

    # --- Session health check ---
    # Retry up to 5 times with 2s sleep between attempts to handle post-sleep
    # server hiccup: when the Mac wakes from sleep, the localhost webhook
    # server may be unreachable for a few seconds while the process resumes.
    # ~10s total recovery window is plenty for a localhost process.
    health_ok=0
    for _attempt in 1 2 3 4 5; do
        HEALTH=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null) || HEALTH=""
        if [ "$HEALTH" = "ok:$SESSION_TOKEN" ]; then
            health_ok=1
            break
        fi
        sleep 2
    done
    if [ "$health_ok" -eq 0 ]; then
        echo "Health check failed after 5 attempts (expected ok:$SESSION_TOKEN, last got '$HEALTH'). Exiting."
        exit 0
    fi

    # --- Single combined gh pr view fetch per loop iteration ---
    # All PR field reads come from this one call; results are cached to a file
    # so that status_line.sh can read them without making its own gh calls.
    # On rate-limit or network error, skip this iteration rather than crashing.
    if ! PR_JSON=$(gh pr view "$BRANCH" --json url,number,state,mergeable,mergeStateStatus,mergeCommit 2>&1); then
        echo "Warning: gh pr view failed: $PR_JSON — will retry next iteration" >&2
        PR_JSON=""
    fi
    if [ -n "$PR_JSON" ]; then
        _pr_tmp=$(mktemp "/tmp/ci_watch_pr_${SLOT}.XXXXXX")
        printf '%s' "$PR_JSON" > "$_pr_tmp"
        mv -f "$_pr_tmp" "/tmp/ci_watch_pr_${SLOT}"
    fi

    # Extract all needed field values from the cached JSON.
    MERGEABLE=$(printf '%s' "$PR_JSON" | jq -r '.mergeable // ""')
    merge_state_status=$(printf '%s' "$PR_JSON" | jq -r '.mergeStateStatus // ""')
    pr_state=$(printf '%s' "$PR_JSON" | jq -r '.state // ""')
    merge_commit_oid=$(printf '%s' "$PR_JSON" | jq -r 'if .mergeCommit then .mergeCommit.oid else "" end')

    # --- Check if PR was merged ---
    if [ -z "$MERGED" ]; then
        check_merged "$pr_state" "$merge_commit_oid"
    fi

    # --- Merged path: track main CI for the merge commit ---
    if [ -n "$MERGED" ]; then
        write_state "merging"   # refresh mtime so statusline freshness gate doesn't drop it
        # Wrap in `if !` so set -e doesn't abort if the function ever returns
        # non-zero in the future (e.g. an internal jq pipefail).
        if ! MAIN_RUNS_JSON=$(fetch_runs_for "$DEFAULT_BRANCH"); then
            MAIN_RUNS_JSON="[]"
        fi
        if ! SHA_RUNS=$(get_sha_runs_for "$MAIN_RUNS_JSON" "$MERGE_COMMIT_SHA"); then
            SHA_RUNS="[]"
        fi

        [[ -z "$SHA_RUNS" ]] && SHA_RUNS='[]'
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
            KEEP_STATE_FILE=1
            exit 0
        fi

        sleep "$POLL_INTERVAL"
        continue
    fi

    # --- Branch tracking path ---
    # MERGEABLE, merge_state_status already extracted from PR_JSON above.
    # fetch_runs_for already handles gh failures internally and returns "[]"
    # on transient errors, so RUNS_JSON is always valid JSON. Still wrap in
    # `if !` to keep set -e from aborting on any unexpected non-zero return.
    if ! RUNS_JSON=$(fetch_runs_for "$BRANCH"); then
        RUNS_JSON="[]"
    fi

    check_pr_condition "$MERGEABLE" "CONFLICTING" "REPORTED_CONFLICT" "CI FAILURE on branch $BRANCH: PR has merge conflicts. Delegate the fix to coder-agent." "conflict"
    check_pr_condition "$merge_state_status" "BEHIND" "REPORTED_BEHIND" "CI FAILURE on branch $BRANCH: PR is behind the base branch and needs to be updated. Run /sync to update the branch." "behind"

    [[ -z "$RUNS_JSON" ]] && RUNS_JSON='[]'
    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    detect_new_sha

    # Wrap in `if !` so set -e doesn't abort if get_sha_runs_for ever returns
    # non-zero (e.g. jq pipefail on malformed RUNS_JSON).
    if ! SHA_RUNS=$(get_sha_runs_for "$RUNS_JSON" "$LATEST_SHA"); then
        SHA_RUNS="[]"
    fi

    [[ -z "$SHA_RUNS" ]] && SHA_RUNS='[]'
    if [ "$(printf '%s' "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
        SHA_RUNS_EMPTY_COUNT=$((SHA_RUNS_EMPTY_COUNT + 1))
        if [[ "$REPORTED_NO_RUNS" == "false" && "$SHA_RUNS_EMPTY_COUNT" -ge "$SHA_RUNS_EMPTY_MAX" ]]; then
            REPORTED_NO_RUNS=true
            # Fire webhook notification (same pattern used elsewhere in the script).
            curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT" --data-raw "⚠️ No CI runs visible for ${BRANCH} after 2 min — workflow may be missing or still queuing." || true
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    # Reset on successful run detection.
    SHA_RUNS_EMPTY_COUNT=0
    REPORTED_NO_RUNS=false

    check_failures "branch" REPORTED_FAIL
    check_all_passed "branch" REPORTED_PASS

    sleep "$POLL_INTERVAL"
done
