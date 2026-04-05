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
#
# Notification (non-exit) conditions:
#   - CI failed — notifies via webhook and keeps watching
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
set -euo pipefail

# --- Configuration ---
BRANCH="${1:?Usage: ci_watch_persistent.sh <branch>}"
POLL_INTERVAL=5
LATEST_SHA=$(gh api "repos/{owner}/{repo}/commits/$BRANCH" --jq '.sha')
REPORTED_PASS=""
REPORTED_FAIL=""
REPORTED_CONFLICT=""
REPORTED_BEHIND=""
RUNS_JSON=""
SHA_RUNS=""

# --- Session dedup check ---
_find_claude_session_pid() {
  local registry="$HOME/.claude_session_id_to_port"
  [ -f "$registry" ] || return 1

  local node
  node=$(which node 2>/dev/null || echo /usr/local/bin/node)

  local claude_pids
  claude_pids=$("$node" -e "
    const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
    console.log(Object.keys(r).join('\n'));
  " -- "$registry" 2>/dev/null) || return 1
  [ -z "$claude_pids" ] && return 1

  local my_ancestors=()
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    my_ancestors+=("$pid")
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done

  local best_pid=""
  local best_depth=99999

  for cpid in $claude_pids; do
    ps -p "$cpid" > /dev/null 2>&1 || continue
    local walk="$cpid"
    while [ "$walk" -gt 1 ]; do
      local idx=0
      for anc in "${my_ancestors[@]}"; do
        if [ "$anc" = "$walk" ]; then
          if [ "$idx" -lt "$best_depth" ]; then
            best_depth="$idx"
            best_pid="$cpid"
          fi
          break 2
        fi
        idx=$((idx + 1))
      done
      walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$walk" ] && break
    done
  done

  [ -n "$best_pid" ] && echo "$best_pid"
}

CLAUDE_SESSION_PID=$(_find_claude_session_pid || true)
if [ -n "$CLAUDE_SESSION_PID" ]; then
  EXISTING_PIDS=$(pgrep -f "ci_watch_persistent.sh $BRANCH" 2>/dev/null || true)
  for WPID in $EXISTING_PIDS; do
    [ "$WPID" = "$$" ] && continue  # skip self
    WALK="$WPID"
    while [ "$WALK" -gt 1 ]; do
      if [ "$WALK" = "$CLAUDE_SESSION_PID" ]; then
        echo "CI watcher is already running for this session (branch: $BRANCH, PID: $WPID). No need to re-launch." >&2
        exit 1
      fi
      WALK=$(ps -p "$WALK" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$WALK" ] && break
    done
  done
fi

# --- Functions ---

fetch_runs() {
    RUNS_JSON=$(gh run list --branch "$BRANCH" --json databaseId,status,conclusion,name,headSha)
}

check_merge_conflict() {
    MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>&1) || MERGEABLE=""
    if [ "$MERGEABLE" = "CONFLICTING" ]; then
        if [ -z "$REPORTED_CONFLICT" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: PR has merge conflicts. Delegate the fix to coder-agent." || true
            REPORTED_CONFLICT=1
        fi
    else
        REPORTED_CONFLICT=""
    fi
}

check_branch_behind() {
    MERGE_STATE=$(gh pr view "$BRANCH" --json mergeStateStatus --jq '.mergeStateStatus' 2>&1) || MERGE_STATE=""
    if [ "$MERGE_STATE" = "BEHIND" ]; then
        if [ -z "$REPORTED_BEHIND" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: PR is behind the base branch and needs to be updated. Run /sync to update the branch." || true
            REPORTED_BEHIND=1
        fi
    else
        REPORTED_BEHIND=""
    fi
}

detect_new_sha() {
    CURRENT_SHA=$(echo "$RUNS_JSON" | jq -r '.[0].headSha')
    if [ "$CURRENT_SHA" != "$LATEST_SHA" ]; then
        echo "New push detected on branch '$BRANCH' (new SHA: $CURRENT_SHA). Now tracking new CI run."
        LATEST_SHA="$CURRENT_SHA"
        REPORTED_PASS=""
        REPORTED_FAIL=""
        REPORTED_CONFLICT=""
        REPORTED_BEHIND=""
    fi
}

get_sha_runs() {
    SHA_RUNS=$(echo "$RUNS_JSON" | jq --arg sha "$LATEST_SHA" '
      [.[] | select(.headSha == $sha)]
      | group_by(.name)
      | map(sort_by(.databaseId) | last)
    ')
}

check_failures() {
    FAILED_RUNS=$(echo "$SHA_RUNS" | jq '[.[] | select(.status == "completed" and .conclusion == "failure")]')
    if [ "$(echo "$FAILED_RUNS" | jq 'length')" -gt 0 ]; then
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
        MSG="${MSG} Run 'gh run view $FIRST_FAILED_ID --log-failed' to get the logs."
        MSG="${MSG} Delegate the fix to coder-agent."
        if [ -z "$REPORTED_FAIL" ]; then
            bash "$HOME/.claude/channel/notify.sh" "CI FAILURE on branch $BRANCH: $MSG" || true
            REPORTED_FAIL=1
        fi
    fi
}

check_all_passed() {
    if [ "$(echo "$SHA_RUNS" | jq '[.[] | select(.status != "completed")] | length')" -eq 0 ]; then
        if [ -z "$REPORTED_PASS" ]; then
            bash "$HOME/.claude/channel/notify.sh" "✅ CI passed on branch $BRANCH" || true
            REPORTED_PASS=1
        fi
    fi
}

# --- Main loop ---

while true; do
    fetch_runs

    check_merge_conflict
    check_branch_behind

    # If no runs yet, just keep polling
    if [ "$(echo "$RUNS_JSON" | jq 'length')" = "0" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    detect_new_sha

    # Already reported pass for this SHA — just wait for new push
    if [ -n "$REPORTED_PASS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    get_sha_runs

    # No runs for our SHA yet
    if [ "$(echo "$SHA_RUNS" | jq 'length')" -eq 0 ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    check_failures
    check_all_passed

    sleep "$POLL_INTERVAL"
done
