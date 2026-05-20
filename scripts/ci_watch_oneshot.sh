#!/usr/bin/env bash
# ci_watch_oneshot.sh
#
# One-shot PR CI watcher. Polls a single PR until all its checks reach a
# terminal state (no PENDING/QUEUED/IN_PROGRESS rollup entries remain), then
# POSTs a single notification to the local webhook on $PORT, then exits.
#
# Webhook contract matches ci_watch.py: POST raw message body to
# http://127.0.0.1:$PORT/ (no special headers required for the notify path;
# the token is only used for /health).
#
# Usage: ci_watch_oneshot.sh <repo> <pr_number> <port> <token> <label>
#
# Designed to be launched detached via shell-level backgrounding so the
# process survives the spawning subagent's exit:
#   nohup ci_watch_oneshot.sh ... </dev/null >>/tmp/foo.log 2>&1 &
#
# Polling cadence: 30s per iteration. The watcher does not enforce its own
# wall-clock timeout — it relies on PR terminal state. Safety cap below
# bails after ~6h to avoid orphaned processes.

set -u  # unset vars are a bug; intentionally NO -e because we want to keep
        # polling through transient gh failures.

REPO="$1"           # e.g. sunsay-ltd/hub
PR="$2"             # PR number
PORT="$3"           # webhook port
TOKEN="$4"          # session token (only used to sanity-check webhook is ours)
LABEL="$5"          # human-readable label included in the notification

# Safety cap: ~6h at 30s/iter == 720 iters. Prevents zombie watchers if
# something goes badly wrong with the GitHub API or the webhook server.
MAX_ITERS=720
SLEEP_SEC=30

log() {
  # All output goes to whatever stream the caller redirected to (a log file).
  printf '[ci_watch_oneshot %s] %s\n' "$LABEL" "$*"
}

# Health check (best-effort) — confirm the webhook is the one we expect.
# If it's not, we still proceed; the notification just won't reach anyone.
health=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
if [[ "$health" != "ok:$TOKEN" ]]; then
  log "warning: webhook health mismatch (got: $health)"
fi

log "starting watcher repo=$REPO pr=$PR pid=$$"

iter=0
while (( iter < MAX_ITERS )); do
  iter=$((iter + 1))

  # Pull the full rollup. We treat any of: QUEUED, IN_PROGRESS, PENDING as
  # non-terminal. Anything else (SUCCESS, FAILURE, CANCELLED, TIMED_OUT,
  # ACTION_REQUIRED, NEUTRAL, SKIPPED, STALE) is terminal.
  rollup_json=$(gh pr view "$PR" --repo "$REPO" \
    --json statusCheckRollup,state,mergedAt 2>/dev/null || true)

  if [[ -z "$rollup_json" ]]; then
    log "iter=$iter: gh pr view failed; retrying"
    sleep "$SLEEP_SEC"
    continue
  fi

  # If the PR has been merged/closed, also exit early with that info.
  pr_state=$(printf '%s' "$rollup_json" | jq -r '.state // ""')
  if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
    log "iter=$iter: PR is $pr_state — exiting watcher"
    msg="PR $REPO#$PR ($LABEL) is now $pr_state"
    curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT/" \
      --data "$msg" >/dev/null 2>&1 || true
    exit 0
  fi

  # GitHub's statusCheckRollup retains historical CheckRun entries when a
  # check is re-run (same workflowName+name appears multiple times). We
  # must dedupe to the *latest* entry per (workflowName, name) before
  # counting — otherwise an old FAILURE entry hides a fresh SUCCESS.
  #
  # Strategy: group_by workflowName+name and keep the max(completedAt
  # or startedAt). This mirrors what `gh pr checks` does internally.
  dedup_rollup=$(printf '%s' "$rollup_json" | jq '
    [ .statusCheckRollup
      | group_by((.workflowName // "") + "::" + (.name // .context // ""))
      | map( sort_by(.completedAt // .startedAt // "") | last )
      | .[]
    ]
  ')

  # Count any rollup entry that is still in flight. We look at both
  # CheckRun (status field) and StatusContext (state field).
  pending=$(printf '%s' "$dedup_rollup" | jq '
    [.[]
     | select(
         (.status // "" | ascii_upcase) as $s
         | (.state  // "" | ascii_upcase) as $t
         | ($s == "QUEUED" or $s == "IN_PROGRESS" or $s == "PENDING"
            or $t == "PENDING" or $t == "EXPECTED")
       )
    ] | length
  ')

  if [[ "$pending" -gt 0 ]]; then
    if (( iter % 10 == 1 )); then
      log "iter=$iter: $pending checks still pending"
    fi
    sleep "$SLEEP_SEC"
    continue
  fi

  # Terminal — compute pass/fail summary from the deduped rollup.
  # Treat FAILURE/TIMED_OUT/CANCELLED/ACTION_REQUIRED as non-success.
  fail_count=$(printf '%s' "$dedup_rollup" | jq '
    [.[]
     | (.conclusion // .state // "" | ascii_upcase) as $c
     | select($c == "FAILURE" or $c == "TIMED_OUT" or $c == "CANCELLED"
              or $c == "ACTION_REQUIRED" or $c == "ERROR" or $c == "STARTUP_FAILURE")
    ] | length
  ')

  failed_names=$(printf '%s' "$dedup_rollup" | jq -r '
    [.[]
     | (.conclusion // .state // "" | ascii_upcase) as $c
     | select($c == "FAILURE" or $c == "TIMED_OUT" or $c == "CANCELLED"
              or $c == "ACTION_REQUIRED" or $c == "ERROR" or $c == "STARTUP_FAILURE")
     | (.workflowName // "?") + "/" + (.name // "?")
    ] | join(", ")
  ')

  if [[ "$fail_count" -gt 0 ]]; then
    msg="CI TERMINAL on PR $REPO#$PR ($LABEL): $fail_count failing — $failed_names"
  else
    msg="CI PASSED on PR $REPO#$PR ($LABEL): all checks green"
  fi

  log "iter=$iter: terminal — $msg"
  curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT/" \
    --data "$msg" >/dev/null 2>&1 || true
  exit 0
done

log "max iterations reached without terminal state — giving up"
curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT/" \
  --data "ci_watch_oneshot timeout on PR $REPO#$PR ($LABEL)" \
  >/dev/null 2>&1 || true
exit 0
