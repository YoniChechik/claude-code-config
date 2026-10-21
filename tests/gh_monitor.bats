#!/usr/bin/env bats

WATCHER="${BATS_TEST_DIRNAME}/../scripts/gh_monitor.sh"
NOTIFY_SH="${BATS_TEST_DIRNAME}/../scripts/_notify.sh"
WATCHER_ABS="$(cd "$(dirname "$WATCHER")" && pwd)/$(basename "$WATCHER")"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="testsess"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export GH_MONITOR_VERIFY_SCRIPT=""
    BRANCH="feat-x"

    export GH_MONITOR_CHECK_GRACE_MAX=2
    export GH_MONITOR_CHECK_GRACE_POLL=1
    export GH_MONITOR_MERGE_WAIT_MAX=2
    export GH_MONITOR_MERGE_POLL=1
    export GH_MONITOR_RUN_APPEAR_MAX=2
    export GH_MONITOR_RUN_APPEAR_POLL=1
    export GH_MONITOR_RETRY_MAX=3
    export GH_MONITOR_RETRY_BACKOFF=0
    export GH_MONITOR_ACQUIRE_ATTEMPTS=5
    export GH_MONITOR_EVICT_TERM_WAIT=5
    export GH_MONITOR_EVICT_KILL_WAIT=3
    export GH_MONITOR_NO_PID_WAIT=10
    export GH_MONITOR_PROBE_POLL=1
    export GH_MONITOR_MERGE_SETTLE=0
    export GH_MONITOR_DEPLOY_POLL=0
    export GH_MONITOR_RUN_POLL=0
    export GH_MONITOR_WATCH_MAX=60
    export GH_MONITOR_POLL_FAIL_MAX=3
    export GH_MONITOR_WAIT_POLL=0
    export GH_MONITOR_WAIT_GRACE=0

    source "$NOTIFY_SH"
    KEY=$(_gh_monitor_key "o/r" "$BRANCH")
    SLUG=$(_gh_monitor_slug "$BRANCH")

    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    mkdir -p "$GH_STUB_DIR" "$BATS_TEST_TMPDIR/bin"
    export GH_STUB_DIR
    write_gh_stub
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    stub repo_name 0 "o/r"
    stub api_checks 0 '{"check_runs":[]}'
    stub api_status 0 '{"statuses":[]}'
    stub api_wfruns 0 '{"workflow_runs":[]}'

    SPAWNED_PIDS_FILE="$BATS_TEST_TMPDIR/spawned_pids"
    : >"$SPAWNED_PIDS_FILE"
}

teardown() {
    while read -r pid; do
        [ -n "$pid" ] || continue
        kill -KILL -- -"$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
    done <"$SPAWNED_PIDS_FILE"
    return 0
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in (*"$1"*) ;; (*) return 0 ;; esac
    printf 'expected NOT to contain: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

lockfile_for() { printf '%s/gh_monitor_lock_%s_%s-%s' "$BATS_TEST_TMPDIR" "$1" "$SLUG" "$KEY"; }
pidfile_for() { printf '%s/gh_monitor_pid_%s_%s-%s' "$BATS_TEST_TMPDIR" "$1" "$SLUG" "$KEY"; }

stub() {
    local key="$1" rc="$2"
    shift 2
    { printf '%s\n' "$rc"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } >"$GH_STUB_DIR/$key"
    return 0
}

write_gh_stub() {
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/bin/bash
key=""
case "$1 $2" in
    "repo view")
        case "$*" in
            *nameWithOwner*) key=repo_name ;;
            *defaultBranchRef*) key=repo_default ;;
        esac
        ;;
    "pr view")
        case "$*" in
            *statusCheckRollup*) key=pr_rollup ;;
            *) key=pr_state ;;
        esac
        ;;
    "pr checks") key=pr_checks ;;
    "run list") key=run_list ;;
    "run watch") key=run_watch ;;
    "run view")
        case "$*" in
            *databaseId*) key=run_view_exists ;;
            *jobs*) key=run_view_jobs ;;
            *status,conclusion*) key=run_view_state ;;
        esac
        ;;
    "workflow run") key=workflow_run ;;
esac
case "$1" in
    api)
        case "$*" in
            *actions/workflows/*) key=api_wfruns ;;
            *compare/*) key=api_compare ;;
            *actions/runs*) key=api_runs ;;
            *check-runs*) key=api_checks ;;
            */status*) key=api_status ;;
        esac
        ;;
esac
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls.log"
[ -n "$key" ] || { echo "gh stub: unroutable call: $*" >&2; exit 99; }
n=0
[ -f "$GH_STUB_DIR/$key.n" ] && n=$(cat "$GH_STUB_DIR/$key.n")
n=$((n + 1))
printf '%s' "$n" >"$GH_STUB_DIR/$key.n"
f="$GH_STUB_DIR/$key.$n"
[ -f "$f" ] || f="$GH_STUB_DIR/$key"
[ -f "$f" ] || { echo "gh stub: no fixture for $key: $*" >&2; exit 99; }
rc=$(head -n 1 "$f")
jqexpr=""
if [ "$1" = api ]; then
    prev=""
    for a in "$@"; do
        [ "$prev" = "--jq" ] && jqexpr=$a
        prev=$a
    done
fi
if [ -n "$jqexpr" ] && [ "$rc" = 0 ]; then
    tail -n +2 "$f" | jq -r "$jqexpr" || exit 98
else
    tail -n +2 "$f"
fi
exit "$rc"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

merged_pr() {
    stub pr_state 0 "MERGED	abc123	3951	fix(website): probe health"
    stub api_runs 0 '{"workflow_runs":[]}'
}

runs_json() {
    local spec id name status conclusion attempt event wid branch sha created
    for spec in "$@"; do
        wid=""; branch=""; sha=""; created=""
        IFS=: read -r id name status conclusion attempt event wid branch sha created <<<"$spec"
        jq -nc --argjson id "$id" --arg n "$name" --arg s "$status" --arg c "$conclusion" \
            --argjson a "$attempt" --arg e "$event" --arg wid "$wid" --arg b "$branch" --arg sha "$sha" --arg cr "$created" \
            '{id:$id,name:$n,status:$s,conclusion:(if $c == "" then null else $c end),run_attempt:$a,event:$e,
              workflow_id:(if $wid == "" then null else ($wid | tonumber) end),head_branch:$b,head_sha:$sha,created_at:$cr}'
    done | jq -sc '{workflow_runs: .}'
}

api_runs_fixture() { stub api_runs 0 "$(runs_json "$@")"; }

api_runs_fixture_n() {
    local n="$1"
    shift
    stub "api_runs.$n" 0 "$(runs_json "$@")"
}

api_checks_fixture() {
    local spec id name status conclusion app
    stub api_checks 0 "$(for spec in "$@"; do
        IFS=: read -r id name status conclusion app <<<"$spec"
        jq -nc --argjson id "$id" --arg n "$name" --arg s "$status" --arg c "$conclusion" --arg app "$app" \
            '{id:$id,name:$n,status:$s,conclusion:(if $c == "" then null else $c end),app:{slug:$app}}'
    done | jq -sc '{check_runs: .}')"
}

result_for() { printf '%s/gh_monitor_result_merge_%s-%s' "$BATS_TEST_TMPDIR" "$SLUG" "$KEY"; }
meta_for() { printf '%s/gh_monitor_watch_merge_%s-%s.meta' "$BATS_TEST_TMPDIR" "$SLUG" "$KEY"; }

call_count() { grep -c -- "$1" "$GH_STUB_DIR/calls.log" 2>/dev/null || true; }

start_lock_holder() {
    local lockfile="$1" secs="$2" pidout="$3"
    cat >"$BATS_TEST_TMPDIR/holder.sh" <<'HOLD'
set -m
lockf -t 0 -k "$1" sleep "$2" &
printf '%s' "$!" >"$3"
wait
HOLD
    bash "$BATS_TEST_TMPDIR/holder.sh" "$lockfile" "$secs" "$pidout" &
    printf '%s\n' "$!" >>"$SPAWNED_PIDS_FILE"
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -s "$pidout" ] && ! lockf -t 0 -k "$lockfile" true 2>/dev/null; then
            printf '%s\n' "$(cat "$pidout")" >>"$SPAWNED_PIDS_FILE"
            return 0
        fi
        sleep 1
    done
    echo "lock holder never acquired $lockfile" >&2
    return 1
}

wait_for_file() {
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$1" ] && return 0
        sleep 1
    done
    return 1
}

@test "_gh_monitor_key returns 10 lowercase hex chars" {
    run bash -c "source '$NOTIFY_SH'; _gh_monitor_key 'o/r' 'feat-x'"
    assert_eq 0 "$status"
    assert_eq 10 "${#output}"
    run bash -c "printf '%s' '$output' | grep -qE '^[0-9a-f]{10}\$'"
    assert_eq 0 "$status"
}

@test "_gh_monitor_key matches the raw sha256(owner/repo#branch) recipe" {
    local expected
    expected=$(printf '%s' 'o/r#feat-x' | shasum -a 256 | cut -c1-10)
    run bash -c "source '$NOTIFY_SH'; _gh_monitor_key 'o/r' 'feat-x'"
    assert_eq "$expected" "$output"
}

@test "_gh_monitor_key folds owner/repo into the identity" {
    run bash -c "source '$NOTIFY_SH'; printf '%s %s' \"\$(_gh_monitor_key 'o/r1' 'b')\" \"\$(_gh_monitor_key 'o/r2' 'b')\""
    local a="${output% *}" b="${output#* }"
    [ "$a" != "$b" ] && return 0
    echo "two repos sharing a branch name produced the same key: $a" >&2
    return 1
}

@test "a mode other than push|merge|wait|run is a usage error, exit 2" {
    run bash "$WATCHER" watch "$BRANCH"
    assert_eq 2 "$status"
    assert_contains "Usage:" "$output"
}

@test "a missing branch is a usage error, exit 2" {
    run bash "$WATCHER" push ""
    assert_eq 2 "$status"
}

@test "--repo override skips the nameWithOwner lookup and keys/watches the named repo" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH" --repo "x/y"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"

    local key_xy
    key_xy=$(bash -c "source '$NOTIFY_SH'; _gh_monitor_key 'x/y' '$BRANCH'")
    [ -f "$BATS_TEST_TMPDIR/gh_monitor_lock_push_${SLUG}-${key_xy}" ] \
        || { echo "expected a lock file keyed on x/y" >&2; return 1; }

    assert_not_contains "nameWithOwner" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "--repo x/y" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "merge accepts a PR number as the selector and forwards --repo to every gh call" {
    merged_pr
    api_runs_fixture "999:CI:completed:success:1:push"
    run bash "$WATCHER" merge "123" --repo "x/y"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED for PR #3951" "$output"
    assert_not_contains "nameWithOwner" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "--repo x/y" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "repos/x/y/actions/runs" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "with no --repo override, the watcher still self-resolves via gh repo view (unchanged plain case)" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    assert_contains "nameWithOwner" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "--repo o/r" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "uncontended acquire runs the body and records the lock + pid files" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "all good"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    [ -f "$(lockfile_for push)" ] || { echo "lock file missing" >&2; return 1; }
    run cat "$(pidfile_for push)"
    assert_contains "pgid=" "$output"
    assert_contains "session=testsess" "$output"
}

@test "the lock is genuinely kernel-held while the watcher body runs" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "done"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'SLOWSTUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls.log"
case "$1 $2" in
    "repo view") printf 'o/r\n'; exit 0 ;;
    "pr view") printf '1\n'; exit 0 ;;
    "pr checks") sleep 30; exit 0 ;;
esac
exit 99
SLOWSTUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"

    bash "$WATCHER" push "$BRANCH" >"$BATS_TEST_TMPDIR/out" 2>&1 &
    printf '%s\n' "$!" >>"$SPAWNED_PIDS_FILE"
    wait_for_file "$(pidfile_for push)" || { echo "watcher never wrote its pidfile" >&2; return 1; }

    run lockf -t 0 -k "$(lockfile_for push)" true
    assert_eq 75 "$status"

    run lockf -t 0 -k "$(lockfile_for merge)" true
    assert_eq 0 "$status"
}

@test "contention against a live holder evicts it by pgid and then acquires" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$lock" 120 "$pidout"
    local holder_pgid; holder_pgid=$(cat "$pidout")
    printf 'pgid=%s start=%s session=other\n' "$holder_pgid" "$(date +%s)" >"$(pidfile_for push)"

    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    run kill -0 -- -"$holder_pgid"
    [ "$status" -ne 0 ] || { echo "holder pgid $holder_pgid survived eviction" >&2; return 1; }
}

@test "contention with a missing PIDFILE falls back to lock-probe-only and still acquires" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$lock" 3 "$pidout"
    rm -f "$(pidfile_for push)"

    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
}

@test "contention with a stale PIDFILE pgid still acquires once the holder exits" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$lock" 3 "$pidout"
    printf 'pgid=999999 start=1 session=ghost\n' >"$(pidfile_for push)"

    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
}

@test "an unevictable holder gives up after the bounded attempts, exit nonzero" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$lock" 120 "$pidout"
    rm -f "$(pidfile_for push)"
    export GH_MONITOR_NO_PID_WAIT=1

    run bash "$WATCHER" push "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "Could not acquire lock for feat-x" "$output"
}

@test "push and merge watchers for one branch use different locks and never contend" {
    local pushlock; pushlock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$pushlock" 120 "$pidout"

    stub pr_state 0 "CLOSED	-	7	t"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "closed without merging" "$output"
    run lockf -t 0 -k "$pushlock" true
    assert_eq 75 "$status"
}

make_run_watchable_driver() {
    {
        echo 'set -m'
        sed -n '/^run_watchable() {$/,/^}$/p' "$WATCHER"
        cat
    } >"$BATS_TEST_TMPDIR/rwdrv.sh"
}

make_fake_gh_with_child() {
    cat >"$BATS_TEST_TMPDIR/fakegh.sh" <<'FAKE'
#!/bin/bash
( while :; do sleep 0.2; done ) &
printf '%s' "$!" >"$1"
printf '%s' "$$" >"$2"
wait
FAKE
    chmod +x "$BATS_TEST_TMPDIR/fakegh.sh"
}

run_watchable_signal_case() {
    local signal="$1"
    make_fake_gh_with_child
    make_run_watchable_driver <<DRV
run_watchable "$BATS_TEST_TMPDIR/fakegh.sh" "$BATS_TEST_TMPDIR/child.pid" "$BATS_TEST_TMPDIR/gh.pid"
printf '%s' "\$?" >"$BATS_TEST_TMPDIR/rc"
DRV
    set -m
    bash "$BATS_TEST_TMPDIR/rwdrv.sh" &
    local drv=$!
    set +m
    printf '%s\n' "$drv" >>"$SPAWNED_PIDS_FILE"
    wait_for_file "$BATS_TEST_TMPDIR/child.pid" || { echo "fake gh never spawned its child" >&2; return 1; }
    GH_PID=$(cat "$BATS_TEST_TMPDIR/gh.pid")
    CHILD_PID=$(cat "$BATS_TEST_TMPDIR/child.pid")
    kill -"$signal" "$drv" 2>/dev/null
    wait_for_file "$BATS_TEST_TMPDIR/rc" || { echo "run_watchable never returned" >&2; return 1; }
    OBSERVED_RC=$(cat "$BATS_TEST_TMPDIR/rc")
    return 0
}

@test "run_watchable: TERM kills gh AND gh's own child, and reports 143" {
    run_watchable_signal_case TERM
    assert_eq 143 "$OBSERVED_RC"
    run kill -0 "$GH_PID"
    [ "$status" -ne 0 ] || { echo "the gh stand-in survived" >&2; return 1; }
    run kill -0 "$CHILD_PID"
    [ "$status" -ne 0 ] || { echo "gh's own child survived (pgid signalling failed)" >&2; return 1; }
}

@test "run_watchable: an unsignaled exit passes the real exit code through" {
    make_run_watchable_driver <<'DRV'
run_watchable bash -c 'exit 42'
echo "rc=$?"
run_watchable bash -c 'exit 0'
echo "rc0=$?"
DRV
    run bash "$BATS_TEST_TMPDIR/rwdrv.sh"
    assert_contains "rc=42" "$output"
    assert_contains "rc0=0" "$output"
}

@test "push: an empty rollup that fills mid-grace proceeds to --watch, not 'no checks'" {
    stub pr_rollup.1 0 "0"
    stub pr_rollup.2 0 "0"
    stub pr_rollup.3 0 "2"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    assert_not_contains "No CI checks configured" "$output"
    assert_eq 1 "$(call_count 'pr checks')"
}

@test "push: a rollup still empty at the grace bound announces 'No CI checks configured'" {
    stub pr_rollup 0 "0"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "No CI checks configured for feat-x" "$output"
    assert_eq 0 "$(call_count 'pr checks')"
}

@test "push: a genuine check failure reports FAILED and still exits 0" {
    stub pr_rollup 0 "3"
    stub pr_checks 1 "X  build  1m  failing"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI FAILED for feat-x" "$output"
    assert_eq 1 "$(call_count 'pr checks')"
}

@test "push: a CI job whose name looks transient is never retried into a false pass" {
    stub pr_rollup 0 "1"
    stub pr_checks 1 "X  timeout-probe  2m  failing"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI FAILED for feat-x" "$output"
    assert_eq 1 "$(call_count 'pr checks')"
}

@test "push: a transport error ending gh pr checks --watch is re-armed, not reported as FAILED" {
    stub pr_rollup 0 "3"
    stub pr_checks.1 1 "build	pass	3s	https://x" 'Post "https://api.github.com/graphql": read tcp 1.2.3.4:5->6.7.8.9:443: read: operation timed out'
    stub pr_checks.2 0 "build	pass	3s	https://x"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    assert_not_contains "CI FAILED" "$output"
    assert_eq 2 "$(call_count 'pr checks')"
}

@test "push: a transport error that never clears escalates to a persistent error, never FAILED" {
    stub pr_rollup 0 "3"
    stub pr_checks 1 'Post "https://api.github.com/graphql": read: connection reset by peer'
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 1 "$status"
    assert_contains "persistent error" "$output"
    assert_not_contains "CI FAILED" "$output"
    assert_eq 3 "$(call_count 'pr checks')"
}

@test "push: 'no checks reported' from gh pr checks maps to the no-checks outcome" {
    stub pr_rollup 0 "1"
    stub pr_checks 1 "no checks reported on the 'feat-x' branch"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "No CI checks configured for feat-x" "$output"
    assert_not_contains "CI FAILED" "$output"
}

@test "merge: an already-merged PR reports PR number, title, merge sha and every workflow's conclusion" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push" "12:Deploy Backoffice Backend:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED for PR #3951 \"fix(website): probe health\" on o/r (merge commit abc123): all 2 green" "$output"
    assert_contains "success            CI (run 11, attempt 1, push)" "$output"
    assert_contains "success            Deploy Backoffice Backend (run 12, attempt 1, push)" "$output"
    assert_eq 1 "$(call_count 'pr view')"
    assert_eq "$output" "$(cat "$(result_for)")"
}

@test "merge: the snapshot pins the exact gh api call shapes, check-runs with filter=all" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    local calls; calls=$(cat "$GH_STUB_DIR/calls.log")
    assert_contains "api --paginate repos/o/r/actions/runs?head_sha=abc123&per_page=100 --jq" "$calls"
    assert_contains "api --paginate repos/o/r/commits/abc123/check-runs?filter=all&per_page=100 --jq" "$calls"
    assert_contains "api repos/o/r/commits/abc123/status --jq" "$calls"
    assert_contains "pr view feat-x --repo o/r --json state,mergeCommit,number,title" "$calls"
    assert_not_contains "run watch" "$calls"
    assert_not_contains "repo view --repo" "$calls"
}

@test "merge: a run stuck at status in_progress but with conclusion success is finished and green" {
    merged_pr
    api_runs_fixture "11:Website Release:in_progress:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "merge: a failed first attempt followed by a green re-run is not a failure" {
    merged_pr
    api_runs_fixture_n 1 "11:gates:completed:failure:1:push"
    api_runs_fixture "11:gates:completed:failure:1:push" "11:gates:completed:success:2:push"
    api_checks_fixture "5:pr-title-lint:completed:failure:github-actions" "7:vercel:completed:failure:vercel" "8:vercel:completed:success:vercel"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "gates (run 11, attempt 2, push)" "$output"
    assert_contains "vercel (check run, vercel)" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "merge: a real failure is reported FAILED, failing workflow listed first, exit 0" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push" "12:Deploy Backoffice Backend:completed:failure:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI FAILED for PR #3951 \"fix(website): probe health\" on o/r (merge commit abc123): 1 of 2 failed" "$output"
    assert_eq "  failure            Deploy Backoffice Backend (run 12, attempt 1, push)" "$(printf '%s\n' "$output" | sed -n 2p)"
}

@test "merge: cancelled, timed_out and action_required all count as failures" {
    merged_pr
    api_runs_fixture "11:A:completed:cancelled:1:push" "12:B:completed:timed_out:1:push" "13:C:completed:action_required:1:push" "14:D:completed:skipped:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "3 of 4 failed" "$output"
}

wfruns_fixture() {
    local spec id status conclusion sha created
    stub api_wfruns 0 "$(for spec in "$@"; do
        IFS=: read -r id status conclusion sha created <<<"$spec"
        jq -nc --argjson id "$id" --arg s "$status" --arg c "$conclusion" --arg sha "$sha" --arg cr "$created" \
            '{id:$id,status:$s,conclusion:(if $c == "" then null else $c end),head_sha:$sha,created_at:$cr}'
    done | jq -sc '{workflow_runs: .}')"
}

@test "merge: a cancelled run superseded by a later descendant run that succeeded passes" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "21:completed:success:def456:c2" "11:completed:cancelled:abc123:c1"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED for PR #3951 \"fix(website): probe health\" on o/r (merge commit abc123): all 1 green" "$output"
    assert_contains "superseded         Release (run 11, attempt 1, push, superseded by run 21)" "$output"
    assert_not_contains "FAILED" "$output"
}


@test "merge: a cancelled run whose superseder failed fails the verdict" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "21:completed:failure:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED for PR #3951 \"fix(website): probe health\" on o/r (merge commit abc123): 1 of 1 failed" "$output"
    assert_contains "failure            Release (run 11, attempt 1, push, superseded by run 21)" "$output"
}

@test "merge: a cancelled run with no later run of its workflow still fails" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "11:completed:cancelled:abc123:c1"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "cancelled          Release (run 11, attempt 1, push)" "$output"
    assert_eq 0 "$(call_count 'compare/')"
}

@test "merge: a cancelled superseder is skipped for an older live run that succeeded" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "31:completed:cancelled:fff111:c3" "21:completed:success:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded         Release (run 11, attempt 1, push, superseded by run 21)" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "merge: a cancelled superseder skipped for an older pending run keeps the watcher waiting" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    stub api_wfruns.1 0 "$(jq -nc '{workflow_runs:[{id:31,status:"completed",conclusion:"cancelled",head_sha:"fff111",created_at:"c3"},{id:21,status:"in_progress",conclusion:null,head_sha:"def456",created_at:"c2"}]}')"
    stub api_wfruns 0 "$(jq -nc '{workflow_runs:[{id:31,status:"completed",conclusion:"cancelled",head_sha:"fff111",created_at:"c3"},{id:21,status:"completed",conclusion:"success",head_sha:"def456",created_at:"c2"}]}')"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    [ "$(call_count 'actions/runs')" -ge 2 ] || { echo "expected a second poll" >&2; return 1; }
}

@test "merge: a chain of cancelled runs with no live successor is not green" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "31:completed:cancelled:fff111:c3" "21:completed:cancelled:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "cancelled          Release (run 11, attempt 1, push, superseded by run 31)" "$output"
}

@test "merge: a later run on a diverged (non-descendant) sha does not supersede" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "21:completed:success:def456:c2"
    stub api_compare 0 '{"status":"diverged"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "cancelled          Release (run 11, attempt 1, push)" "$output"
}

@test "merge: two cancelled runs of one workflow share one superseder lookup" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1" "12:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "21:completed:success:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "all 2 green" "$output"
    local polls; polls=$(call_count 'actions/runs')
    assert_eq "$polls" "$(call_count 'actions/workflows/')"
    assert_eq 1 "$(call_count 'compare/')"
}

@test "merge: a cancelled workflow_dispatch run is judged by a later dispatch of its workflow" {
    merged_pr
    api_runs_fixture "11:Mobile Store Status:completed:cancelled:1:workflow_dispatch:7:main:abc123:c1" \
        "12:Mobile Store Status:completed:success:1:workflow_dispatch:7:main:abc123:c2" \
        "13:Mobile Store Status:completed:cancelled:1:workflow_dispatch:7:main:abc123:c3"
    wfruns_fixture "14:completed:success:def456:c4" "13:completed:cancelled:abc123:c3" "12:completed:success:abc123:c2" "11:completed:cancelled:abc123:c1"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "all 3 green" "$output"
    assert_contains "superseded         Mobile Store Status (run 11, attempt 1, workflow_dispatch, superseded by run 12)" "$output"
    assert_contains "superseded         Mobile Store Status (run 13, attempt 1, workflow_dispatch, superseded by run 14)" "$output"
    assert_contains "api --paginate --method GET repos/o/r/actions/workflows/7/runs -f branch=main -f event=workflow_dispatch -f created=>=c1 -f per_page=100" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "-f created=>=c3" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_not_contains "-f event=push" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "merge: a cancelled workflow_dispatch run whose later dispatch failed fails the verdict" {
    merged_pr
    api_runs_fixture "11:Mobile Store Status:completed:cancelled:1:workflow_dispatch:7:main:abc123:c1"
    wfruns_fixture "12:completed:failure:abc123:c2" "11:completed:cancelled:abc123:c1"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "failure            Mobile Store Status (run 11, attempt 1, workflow_dispatch, superseded by run 12)" "$output"
}

@test "merge: a cancelled run is judged by the end of its supersede chain, not by the newest run on a busy branch" {
    merged_pr
    api_runs_fixture "11:Backoffice Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "24:in_progress::aaa444:c5" "23:completed:cancelled:aaa333:c4" "22:completed:success:aaa222:c3" "21:completed:cancelled:aaa111:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded         Backoffice Release (run 11, attempt 1, push, superseded by run 22)" "$output"
    assert_not_contains "run 24" "$output"
}

@test "merge: a failed chain end is cleared by a later run containing the merge that succeeded" {
    merged_pr
    api_runs_fixture "11:Website Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "24:in_progress::aaa444:c5" "23:completed:success:aaa333:c4" "22:completed:cancelled:aaa222:c3" "21:completed:failure:aaa111:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded         Website Release (run 11, attempt 1, push, superseded by run 23)" "$output"
}

@test "merge: a cancelled run whose chain end is a later pending run is terminal superseded-pending" {
    merged_pr
    api_runs_fixture "11:Website Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "23:queued::aaa333:c4" "22:in_progress::aaa222:c3" "21:completed:failure:aaa111:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run timeout 30 bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded-pending Website Release (run 11, attempt 1, push, superseded by run 22)" "$output"
}

@test "merge: when every later run containing the merge failed, the newest failure fails the verdict" {
    merged_pr
    api_runs_fixture "11:Website Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "23:completed:cancelled:aaa333:c4" "22:completed:failure:aaa222:c3" "21:completed:failure:aaa111:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "failure            Website Release (run 11, attempt 1, push, superseded by run 22)" "$output"
}

@test "merge: when the chain's pending run is itself superseded the watcher follows the chain to its new end" {
    merged_pr
    api_runs_fixture "11:Backoffice Release:completed:cancelled:1:push:5:main:abc123:c1"
    stub api_wfruns.1 0 "$(jq -nc '{workflow_runs:[{id:21,status:"in_progress",conclusion:null,head_sha:"def456",created_at:"c2"}]}')"
    stub api_wfruns 0 "$(jq -nc '{workflow_runs:[{id:22,status:"completed",conclusion:"success",head_sha:"fff111",created_at:"c3"},{id:21,status:"completed",conclusion:"cancelled",head_sha:"def456",created_at:"c2"}]}')"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded         Backoffice Release (run 11, attempt 1, push, superseded by run 22)" "$output"
}

@test "merge: a later run that does not contain the merge is skipped on the way to the chain end" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "22:completed:success:ddd222:c3" "21:completed:success:ddd111:c2"
    stub api_compare.1 0 '{"status":"diverged"}'
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "superseded         Release (run 11, attempt 1, push, superseded by run 22)" "$output"
}

@test "merge: a non-Actions check run that failed on its latest attempt fails the verdict" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    api_checks_fixture "7:codecov:completed:success:codecov" "9:codecov:completed:failure:codecov"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "failure            codecov (check run, codecov)" "$output"
}

@test "merge: a failing commit status fails the verdict; a pending one keeps it waiting" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    stub api_status.1 0 '{"statuses":[{"id":1,"context":"ext/deploy","state":"pending"}]}'
    stub api_status 0 '{"statuses":[{"id":2,"context":"ext/deploy","state":"failure"}]}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "failure            ext/deploy (commit status)" "$output"
}

@test "merge: runs still in progress are waited for, never reported early" {
    merged_pr
    api_runs_fixture_n 1 "11:CI:in_progress::1:push"
    api_runs_fixture_n 2 "11:CI:queued::1:push"
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
    [ "$(call_count 'actions/runs')" -ge 3 ] || { echo "expected at least 3 polls" >&2; return 1; }
}

@test "merge: a deploy cascade that registers after the first runs finished is included in the verdict" {
    merged_pr
    api_runs_fixture_n 1 "11:CI:completed:success:1:push"
    api_runs_fixture_n 2 "11:CI:completed:success:1:push" "12:Deploy:queued::1:workflow_run"
    api_runs_fixture "11:CI:completed:success:1:push" "12:Deploy:completed:failure:1:workflow_run"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED" "$output"
    assert_contains "Deploy (run 12, attempt 1, workflow_run)" "$output"
}

@test "merge: the settle window holds the verdict even when everything is already green" {
    export GH_MONITOR_MERGE_SETTLE=3
    export GH_MONITOR_DEPLOY_POLL=1
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    local t0; t0=$(date +%s)
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    [ $(($(date +%s) - t0)) -ge 3 ] || { echo "verdict came before the settle window" >&2; return 1; }
    [ "$(call_count 'actions/runs')" -ge 2 ] || { echo "expected the settle window to span polls" >&2; return 1; }
}

@test "merge: scheduled and issue_comment runs on the same sha are ignored" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push" "12:Nightly:completed:failure:1:schedule" "13:Bot:completed:failure:1:issue_comment"
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED for PR #3951 \"fix(website): probe health\" on o/r (merge commit abc123): all 1 green" "$output"
    assert_not_contains "Nightly" "$output"
}

@test "merge: a transport error mid-poll is retried on the next poll, never reported as FAILED" {
    merged_pr
    stub api_runs.1 1 'Get "https://api.github.com/repos/o/r/actions/runs": read: connection reset by peer'
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "merge: polls that keep failing escalate to a persistent error, never FAILED" {
    merged_pr
    stub api_runs 1 "HTTP 502: Bad Gateway"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 1 "$status"
    assert_contains "hit a persistent error" "$output"
    assert_not_contains "CI FAILED" "$output"
    assert_eq 3 "$(call_count 'actions/runs')"
    assert_contains "hit a persistent error" "$(cat "$(result_for)")"
}

@test "merge: no post-merge run inside the appearance grace is announced as such" {
    export GH_MONITOR_RUN_APPEAR_MAX=0
    merged_pr
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "PR #3951 \"fix(website): probe health\" merged on o/r (merge commit abc123); no post-merge CI run started within 0s" "$output"
}

@test "merge: runs still pending at the watch bound report an UNKNOWN verdict with their states" {
    export GH_MONITOR_WATCH_MAX=0
    merged_pr
    api_runs_fixture "11:Deploy:waiting::1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge verdict UNKNOWN (timeout): CI watch for PR #3951" "$output"
    assert_contains "waiting            Deploy (run 11, attempt 1, push)" "$output"
}

@test "merge: every run cancelled and superseded by completed successes passes" {
    merged_pr
    api_runs_fixture "11:Release:completed:cancelled:1:push:5:main:abc123:c1" "12:Deploy:completed:cancelled:1:push:6:main:abc123:c1"
    wfruns_fixture "21:completed:success:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "all 2 green" "$output"
    assert_not_contains "UNKNOWN" "$output"
}

@test "merge: a success next to a cancelled run superseded by a success passes" {
    merged_pr
    api_runs_fixture "10:Gates:completed:success:1:push:4:main:abc123:c1" "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    wfruns_fixture "21:completed:success:def456:c2"
    stub api_compare 0 '{"status":"ahead"}'
    run bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI PASSED" "$output"
    assert_contains "all 2 green" "$output"
    assert_contains "superseded         Release (run 11, attempt 1, push, superseded by run 21)" "$output"
}

@test "merge: cancelled runs whose superseder is still running pass without waiting and still verify staging" {
    merged_pr
    write_verify_stub
    api_runs_fixture "10:Gates:completed:success:1:push:4:main:abc123:c1" "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    stub api_wfruns 0 "$(jq -nc '{workflow_runs:[{id:21,status:"in_progress",conclusion:null,head_sha:"def456",created_at:"c2"}]}')"
    stub api_compare 0 '{"status":"ahead"}'
    run timeout 30 bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED for PR #3951" "$output"
    assert_contains "superseded-pending Release (run 11, attempt 1, push, superseded by run 21)" "$output"
    assert_eq "o/r $BRANCH 3951 abc123 pass" "$(cat "$BATS_TEST_TMPDIR/verify_calls.log")"
    assert_not_contains "UNKNOWN" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "merge: a real pending run next to a pending chain still times out UNKNOWN" {
    export GH_MONITOR_WATCH_MAX=1
    merged_pr
    api_runs_fixture "10:Deploy:in_progress::1:push:4:main:abc123:c1" "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    stub api_wfruns 0 "$(jq -nc '{workflow_runs:[{id:21,status:"in_progress",conclusion:null,head_sha:"def456",created_at:"c2"}]}')"
    stub api_compare 0 '{"status":"ahead"}'
    run timeout 30 bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge verdict UNKNOWN (timeout)" "$output"
    assert_contains "1 still pending, 0 failed so far" "$output"
}

@test "merge: a real failure next to a pending superseded run fails the verdict" {
    merged_pr
    api_runs_fixture "10:Deploy:completed:failure:1:push:4:main:abc123:c1" "11:Release:completed:cancelled:1:push:5:main:abc123:c1"
    stub api_wfruns 0 "$(jq -nc '{workflow_runs:[{id:21,status:"in_progress",conclusion:null,head_sha:"def456",created_at:"c2"}]}')"
    stub api_compare 0 '{"status":"ahead"}'
    run timeout 30 bash "$WATCHER" merge "$BRANCH"
    assert_contains "Post-merge CI FAILED for PR #3951" "$output"
}

@test "merge: a PR closed without merging is reported and never treated as an error" {
    stub pr_state 0 "CLOSED	-	7	some title"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "PR #7 \"some title\" on o/r closed without merging" "$output"
    assert_eq 0 "$(call_count 'actions/runs')"
}

@test "merge: a PR merged mid-wait is picked up on a later poll" {
    export GH_MONITOR_MERGE_WAIT_MAX=30
    stub pr_state.1 0 "OPEN	-	3951	fix(website): probe health"
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED" "$output"
}

@test "merge: a PR still open at MERGE_WAIT_MAX times out with the retry instruction" {
    export GH_MONITOR_MERGE_WAIT_MAX=0
    stub pr_state 0 "OPEN	-	3951	t"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI settled wait timed out; feat-x still not merged after 6h" "$output"
    assert_contains "Run \`bash $WATCHER_ABS merge feat-x --repo o/r\` after you merge it." "$output"
}

@test "merge: writes a session-tagged meta file naming the result file and the waiter command" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    local meta; meta=$(meta_for)
    assert_contains "session=testsess" "$(cat "$meta")"
    assert_contains "target=feat-x" "$(cat "$meta")"
    assert_contains "repo=o/r" "$(cat "$meta")"
    assert_contains "result=$(result_for)" "$(cat "$meta")"
    assert_contains "wait_cmd=bash $WATCHER_ABS wait feat-x --repo o/r" "$(cat "$meta")"
}

@test "merge --detach returns at once with the meta path; the detached watcher writes the result; wait prints it" {
    merged_pr
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH" --repo o/r --detach
    assert_eq 0 "$status"
    assert_eq "$(meta_for)" "$output"
    export GH_MONITOR_WAIT_POLL=1
    export GH_MONITOR_WAIT_GRACE=20
    run bash "$WATCHER" wait "$BRANCH" --repo o/r
    assert_eq 0 "$status"
    assert_contains "Post-merge CI PASSED for PR #3951" "$output"
    assert_contains "CI (run 11, attempt 1, push)" "$output"
}

@test "wait: no watcher and no result says so instead of hanging" {
    export GH_MONITOR_WAIT_GRACE=0
    run bash "$WATCHER" wait "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "No merge watcher is running for feat-x on o/r" "$output"
    assert_contains "merge feat-x --repo o/r --detach" "$output"
}

@test "wait: a watcher that never records a result ends in an UNKNOWN timeout verdict" {
    export GH_MONITOR_WAIT_GRACE=100
    export GH_MONITOR_WAIT_POLL=1
    export GH_MONITOR_WAIT_MAX=2
    run timeout 30 bash "$WATCHER" wait "$BRANCH" --repo o/r
    assert_eq 0 "$status"
    assert_contains "Post-merge verdict UNKNOWN (timeout): no result recorded for feat-x on o/r after 2s" "$output"
}

@test "wait: an existing result is printed immediately" {
    printf 'Post-merge CI PASSED for PR #1\n' >"$(result_for)"
    run bash "$WATCHER" wait "$BRANCH"
    assert_eq 0 "$status"
    assert_eq "Post-merge CI PASSED for PR #1" "$output"
}

@test "an auth error is retried 3x and then escalates to one persistent-error line" {
    stub pr_rollup 1 "gh: Bad credentials (HTTP 401)"
    run bash "$WATCHER" push "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "CI watch for feat-x hit a persistent error" "$output"
    assert_contains "run \`bash $WATCHER_ABS push feat-x\` to retry" "$output"
    assert_eq 3 "$(call_count 'statusCheckRollup')"
    assert_not_contains "No CI checks configured" "$output"
}

@test "a rate-limit error is retried, then a later success is used" {
    stub pr_rollup.1 1 "API rate limit exceeded"
    stub pr_rollup.2 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
}

@test "an empty JSON response is retried rather than read as 'no checks'" {
    stub pr_rollup.1 0
    stub pr_rollup.2 0 "2"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    assert_not_contains "No CI checks configured" "$output"
}

@test "a network error during the merge wait escalates instead of faking a verdict" {
    stub pr_state 1 "dial tcp: i/o timeout"
    run bash "$WATCHER" merge "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "hit a persistent error" "$output"
    assert_not_contains "closed without merging" "$output"
    assert_not_contains "Post-merge CI" "$output"
    assert_contains "--repo o/r\` to retry" "$output"
}

@test "gh chatter goes to the per-key log, never to stdout" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "VERBOSE-GH-CHATTER"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_eq "CI passed for feat-x" "$output"
    run cat "$BATS_TEST_TMPDIR/gh_monitor_push_${SLUG}-${KEY}.log"
    assert_contains "VERBOSE-GH-CHATTER" "$output"
}

@test "the persistent-error retry message reports the invoked symlink path, not the real file's" {
    LINK_DIR="$BATS_TEST_TMPDIR/pi-style-link"
    mkdir -p "$LINK_DIR"
    ln -s "$WATCHER_ABS" "$LINK_DIR/gh_monitor.sh"
    ln -s "$(cd "$(dirname "$NOTIFY_SH")" && pwd)/_notify.sh" "$LINK_DIR/_notify.sh"

    stub pr_rollup 1 "gh: Bad credentials (HTTP 401)"
    run bash "$LINK_DIR/gh_monitor.sh" push "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "run \`bash $LINK_DIR/gh_monitor.sh push feat-x\` to retry" "$output"
    assert_not_contains "$WATCHER_ABS" "$output"
}

@test "run: an existing run id that passes reports a pass line with its conclusion" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "42"
    assert_eq 0 "$status"
    assert_contains "CI run 42 passed for o/r (success)" "$output"
    assert_contains "run view 42 --repo o/r --json status,conclusion" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_not_contains "run watch" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "run: status in_progress with conclusion success is finished and passed" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state 0 "in_progress success"
    run bash "$WATCHER" run "42"
    assert_contains "CI run 42 passed for o/r (success)" "$output"
}

@test "run: an in-progress run is polled until it concludes" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state.1 0 "in_progress "
    stub run_view_state.2 0 "queued "
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "42"
    assert_contains "CI run 42 passed for o/r (success)" "$output"
    assert_eq 3 "$(call_count 'status,conclusion')"
}

@test "run: a transport error while polling is not a failure" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state.1 1 'failed to get run: Get "https://api.github.com/repos/o/r/actions/runs/42": read: connection reset by peer'
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "42"
    assert_contains "CI run 42 passed for o/r (success)" "$output"
    assert_not_contains "FAILED" "$output"
}

@test "run: an existing run id that fails reports FAILED plus the failing job names" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state 0 "completed failure"
    stub run_view_jobs 0 "build, lint"
    run bash "$WATCHER" run "42"
    assert_eq 0 "$status"
    assert_contains "CI run 42 FAILED for o/r (failure) — failed jobs: build, lint" "$output"
}

@test "run: a failure whose job list can't be fetched still reports FAILED, no job list" {
    stub run_view_exists 0 '{"databaseId":42}'
    stub run_view_state 0 "completed cancelled"
    stub run_view_jobs 99 "boom"
    run bash "$WATCHER" run "42"
    assert_eq 0 "$status"
    assert_contains "CI run 42 FAILED for o/r (cancelled)" "$output"
    assert_not_contains "failed jobs" "$output"
}

@test "run: a run id that never registers within grace announces 'No CI run found'" {
    stub run_view_exists 99 "not found"
    run bash "$WATCHER" run "999"
    assert_eq 0 "$status"
    assert_contains "No CI run found for 999 on o/r" "$output"
    assert_eq 0 "$(call_count 'status,conclusion')"
}

@test "run: a run id that registers mid-grace still gets watched, not declared missing" {
    stub run_view_exists.1 99 "not found"
    stub run_view_exists.2 0 '{"databaseId":42}'
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "42"
    assert_eq 0 "$status"
    assert_contains "CI run 42 passed for o/r" "$output"
    assert_not_contains "No CI run found" "$output"
}

@test "run: --ref/-f without --dispatch is a usage error, exit 2" {
    run bash "$WATCHER" run "42" --ref main
    assert_eq 2 "$status"
    run bash "$WATCHER" run "42" -f key=value
    assert_eq 2 "$status"
}

@test "run --dispatch: dispatches, resolves the new run id, then watches it to a pass" {
    stub workflow_run 0 ""
    stub run_list 0 "77"
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "ci.yml" --dispatch --ref main -f env=staging
    assert_eq 0 "$status"
    assert_contains "CI run 77 passed for o/r" "$output"
    assert_contains "workflow run ci.yml --repo o/r --ref main -f env=staging" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "run --dispatch: a dispatched run that fails reports FAILED with its job list" {
    stub workflow_run 0 ""
    stub run_list 0 "78"
    stub run_view_state 0 "completed failure"
    stub run_view_jobs 0 "app-backend-tests"
    run bash "$WATCHER" run "ci.yml" --dispatch
    assert_eq 0 "$status"
    assert_contains "CI run 78 FAILED for o/r (failure) — failed jobs: app-backend-tests" "$output"
}

@test "run --dispatch: no run appears within the appearance grace is announced as such" {
    export GH_MONITOR_RUN_APPEAR_MAX=0
    stub workflow_run 0 ""
    stub run_list 0
    run bash "$WATCHER" run "ci.yml" --dispatch
    assert_eq 0 "$status"
    assert_contains "Dispatched ci.yml on o/r but no run appeared within 0s" "$output"
    assert_eq 0 "$(call_count 'status,conclusion')"
}

@test "run --dispatch: a run that appears mid-grace is watched, not declared missing" {
    stub workflow_run 0 ""
    stub run_list.1 0
    stub run_list.2 0 "79"
    stub run_view_state 0 "completed success"
    run bash "$WATCHER" run "ci.yml" --dispatch
    assert_eq 0 "$status"
    assert_contains "CI run 79 passed for o/r" "$output"
}

@test "run --dispatch: a dispatch failure escalates via die_persistent with the dispatch flags in the retry command" {
    stub workflow_run 1 "gh: Bad credentials (HTTP 401)"
    run bash "$WATCHER" run "ci.yml" --dispatch --ref main -f env=staging
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "run \`bash $WATCHER_ABS run ci.yml --dispatch --ref main -f env=staging\` to retry" "$output"
}

@test "run and push watchers for the same target string use different locks and never contend" {
    local key42 slug42 runlock
    key42=$(_gh_monitor_key "o/r" "42")
    slug42=$(_gh_monitor_slug "42")
    runlock="$BATS_TEST_TMPDIR/gh_monitor_lock_run_${slug42}-${key42}"
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$runlock" 120 "$pidout"

    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "42"
    assert_eq 0 "$status"
    assert_contains "CI passed for 42" "$output"
    run lockf -t 0 -k "$runlock" true
    assert_eq 75 "$status"
}

write_verify_stub() {
    export GH_MONITOR_VERIFY_SCRIPT="$BATS_TEST_TMPDIR/bin/verify_stub.sh"
    cat >"$GH_MONITOR_VERIFY_SCRIPT" <<'VSTUB'
#!/bin/bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/verify_calls.log"
echo "Staging verify PASSED for $1 (merge commit $4): staging serves ${4:0:12}, 1/1 probes ok"
VSTUB
    chmod +x "$GH_MONITOR_VERIFY_SCRIPT"
}

@test "merge: after a green post-merge CI the staging verifier runs with repo, target, PR, merge sha and the CI verdict, and its line lands in the result" {
    merged_pr
    write_verify_stub
    api_runs_fixture "11:CI:completed:success:1:push"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_eq "o/r $BRANCH 3951 abc123 pass" "$(cat "$BATS_TEST_TMPDIR/verify_calls.log")"
    assert_contains "Staging verify PASSED for o/r (merge commit abc123)" "$output"
    assert_contains "Staging verify PASSED for o/r" "$(cat "$(result_for)")"
}

@test "merge: a failed post-merge CI hands the verifier ci=fail" {
    merged_pr
    write_verify_stub
    api_runs_fixture "11:CI:completed:failure:1:push"
    stub run_view_jobs 0 ""
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq "o/r $BRANCH 3951 abc123 fail" "$(cat "$BATS_TEST_TMPDIR/verify_calls.log")"
}

@test "merge: no post-merge run hands the verifier ci=none" {
    merged_pr
    write_verify_stub
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq "o/r $BRANCH 3951 abc123 none" "$(cat "$BATS_TEST_TMPDIR/verify_calls.log")"
}

@test "merge: a verifier that crashes without a verdict is reported as a failed verify, not silence" {
    merged_pr
    export GH_MONITOR_VERIFY_SCRIPT="$BATS_TEST_TMPDIR/bin/verify_crash.sh"
    printf '#!/bin/bash\nexit 3\n' >"$GH_MONITOR_VERIFY_SCRIPT"
    chmod +x "$GH_MONITOR_VERIFY_SCRIPT"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Staging verify FAILED for o/r (merge commit abc123): the verifier exited 3 without a verdict" "$output"
}

@test "merge: a PR closed without merging never runs the verifier" {
    stub pr_state 0 "CLOSED	-	3951	t"
    write_verify_stub
    run bash "$WATCHER" merge "$BRANCH"
    [ ! -e "$BATS_TEST_TMPDIR/verify_calls.log" ]
}
