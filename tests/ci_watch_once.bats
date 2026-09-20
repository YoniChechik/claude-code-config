#!/usr/bin/env bats
#
# Tests for scripts/ci_watch_once.sh (the one-shot push/merge watcher)
# and for _ci_watch_key in scripts/_notify.sh.
#
# Strategy:
#   - The REAL script is run end to end.  Only two things are substituted: `gh`
#     is a PATH-shadowing stub (the suite must never touch the network), and
#     every /tmp path is redirected into BATS_TEST_TMPDIR via
#     CLAUDE_NOTIFY_TMP_DIR, so a live watcher's real files are never read,
#     written or evicted by this suite.
#   - Every wait/poll/timeout is env-overridable, so the 45s grace, the 6h
#     merge-wait and the 120s run-appearance grace all complete in milliseconds.
#   - The lock tests use REAL `lockf` holders in REAL process groups, and prove
#     the lock is kernel-held by probing it with an independent `lockf -t 0`
#     from the test itself — nothing about the locking is simulated.
#   - `run_watchable` is EXTRACTED verbatim from the shipped script by marker,
#     so a change to the function that is not reflected here fails this suite.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does
# not fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

WATCHER="${BATS_TEST_DIRNAME}/../scripts/ci_watch_once.sh"
NOTIFY_SH="${BATS_TEST_DIRNAME}/../scripts/_notify.sh"
# The script reports its own invoked path (via $SELF) in user-facing retry
# messages, resolved to an absolute path — never a hardcoded ~/.claude
# literal, so assertions must match against this, not a fixed string.
WATCHER_ABS="$(cd "$(dirname "$WATCHER")" && pwd)/$(basename "$WATCHER")"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="testsess"
    BRANCH="feat-x"

    # Every timer near zero: the suite asserts the LOGIC of each bound, never
    # that the wall clock really elapsed.
    export CI_WATCH_CHECK_GRACE_MAX=2
    export CI_WATCH_CHECK_GRACE_POLL=1
    export CI_WATCH_MERGE_WAIT_MAX=2
    export CI_WATCH_MERGE_POLL=1
    export CI_WATCH_RUN_APPEAR_MAX=2
    export CI_WATCH_RUN_APPEAR_POLL=1
    export CI_WATCH_RETRY_MAX=3
    export CI_WATCH_RETRY_BACKOFF=0
    export CI_WATCH_ACQUIRE_ATTEMPTS=5
    export CI_WATCH_EVICT_TERM_WAIT=5
    export CI_WATCH_EVICT_KILL_WAIT=3
    export CI_WATCH_NO_PID_WAIT=10
    export CI_WATCH_PROBE_POLL=1

    # The key/slug the watcher derives for o/r + feat-x, recomputed here through
    # the same shipped helpers rather than hardcoded.
    # shellcheck source=../scripts/_notify.sh
    source "$NOTIFY_SH"
    KEY=$(_ci_watch_key "o/r" "$BRANCH")
    SLUG=$(_ci_slug "$BRANCH")

    GH_STUB_DIR="$BATS_TEST_TMPDIR/ghstub"
    mkdir -p "$GH_STUB_DIR" "$BATS_TEST_TMPDIR/bin"
    export GH_STUB_DIR
    write_gh_stub
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # Always answer the owner/repo lookup every invocation starts with.
    stub repo_name 0 "o/r"

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

# --- helpers ----------------------------------------------------------------

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

lockfile_for() { printf '%s/ci_watch2_lock_%s_%s-%s' "$BATS_TEST_TMPDIR" "$1" "$SLUG" "$KEY"; }
pidfile_for() { printf '%s/ci_watch2_pid_%s_%s-%s' "$BATS_TEST_TMPDIR" "$1" "$SLUG" "$KEY"; }

# Write one stubbed gh response. Args: <key> <exit code> <stdout text...>.
# A key may be sequenced as "<key>.<n>" to answer the n-th call differently.
stub() {
    local key="$1" rc="$2"
    shift 2
    { printf '%s\n' "$rc"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } >"$GH_STUB_DIR/$key"
    return 0
}

# The gh stub: routes on the subcommand, logs every call, and serves either a
# per-call-number fixture ("<key>.<n>") or the flat one ("<key>").
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
tail -n +2 "$f"
exit "$rc"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# How many stubbed gh calls matched a substring.
call_count() { grep -c -- "$1" "$GH_STUB_DIR/calls.log" 2>/dev/null || true; }

# Hold LOCKFILE for real, in its own process group, and report that pgid.
# `set -m` puts the backgrounded `lockf` in a new group whose pgid is its PID,
# which is exactly what the watcher's eviction path expects to signal.
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
    # Wait for the holder to really own the lock before returning.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ -s "$pidout" ] && ! lockf -t 0 -k "$lockfile" true 2>/dev/null; then
            printf '%s\n' "$(cat "$pidout")" >>"$SPAWNED_PIDS_FILE"
            return 0
        fi
        sleep 1
    done
    echo "lock holder never acquired $lockfile" >&2
    return 1
}

# Poll for a file to exist, up to 10s.
wait_for_file() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$1" ] && return 0
        sleep 1
    done
    return 1
}

# --- _ci_watch_key ----------------------------------------------------------

@test "_ci_watch_key returns 10 lowercase hex chars" {
    run bash -c "source '$NOTIFY_SH'; _ci_watch_key 'o/r' 'feat-x'"
    assert_eq 0 "$status"
    assert_eq 10 "${#output}"
    run bash -c "printf '%s' '$output' | grep -qE '^[0-9a-f]{10}\$'"
    assert_eq 0 "$status"
}

@test "_ci_watch_key matches the raw sha256(owner/repo#branch) recipe" {
    local expected
    expected=$(printf '%s' 'o/r#feat-x' | shasum -a 256 | cut -c1-10)
    run bash -c "source '$NOTIFY_SH'; _ci_watch_key 'o/r' 'feat-x'"
    assert_eq "$expected" "$output"
}

@test "_ci_watch_key folds owner/repo into the identity" {
    run bash -c "source '$NOTIFY_SH'; printf '%s %s' \"\$(_ci_watch_key 'o/r1' 'b')\" \"\$(_ci_watch_key 'o/r2' 'b')\""
    local a="${output% *}" b="${output#* }"
    [ "$a" != "$b" ] && return 0
    echo "two repos sharing a branch name produced the same key: $a" >&2
    return 1
}

# --- usage ------------------------------------------------------------------

@test "a mode other than push|merge is a usage error, exit 2" {
    run bash "$WATCHER" watch "$BRANCH"
    assert_eq 2 "$status"
    assert_contains "Usage:" "$output"
}

@test "a missing branch is a usage error, exit 2" {
    run bash "$WATCHER" push ""
    assert_eq 2 "$status"
}

# --- --repo override ---------------------------------------------------------
# The PostToolUse hook trusts an explicit --repo/PR-number from the triggering
# gh command and forwards them here; these regression tests prove the watcher
# actually uses those explicit values downstream, rather than re-resolving
# them from its own cwd.

@test "--repo override skips the nameWithOwner lookup and keys/watches the named repo" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH" --repo "x/y"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"

    # Keyed on x/y, not o/r: the lock file name changes because the identity
    # hash does -- proves OWNER_REPO really came from --repo, not from gh.
    local key_xy
    key_xy=$(bash -c "source '$NOTIFY_SH'; _ci_watch_key 'x/y' '$BRANCH'")
    [ -f "$BATS_TEST_TMPDIR/ci_watch2_lock_push_${SLUG}-${key_xy}" ] \
        || { echo "expected a lock file keyed on x/y" >&2; return 1; }

    # Never called gh repo view for nameWithOwner -- the override short-circuits it.
    assert_not_contains "nameWithOwner" "$(cat "$GH_STUB_DIR/calls.log")"
    # Every gh call below carries the explicit repo.
    assert_contains "--repo x/y" "$(cat "$GH_STUB_DIR/calls.log")"
}

@test "merge accepts a PR number as the selector and forwards --repo to every gh call" {
    stub pr_state 0 "MERGED deadbeef"
    stub repo_default 0 "main"
    stub run_list 0 "999"
    stub run_watch 0 "ok"
    run bash "$WATCHER" merge "123" --repo "x/y"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI passed for the merge of 123 (run 999)" "$output"
    assert_not_contains "nameWithOwner" "$(cat "$GH_STUB_DIR/calls.log")"
    assert_contains "--repo x/y" "$(cat "$GH_STUB_DIR/calls.log")"
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

# --- lock -------------------------------------------------------------------

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
    # gh pr checks blocks, so the watcher sits inside the lock while we probe.
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

    # An INDEPENDENT lockf from the test itself must genuinely fail (75).
    run lockf -t 0 -k "$(lockfile_for push)" true
    assert_eq 75 "$status"

    # And the push lock must NOT block a merge watcher's own, different lock.
    run lockf -t 0 -k "$(lockfile_for merge)" true
    assert_eq 0 "$status"
}

@test "contention against a live holder evicts it by pgid and then acquires" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$lock" 120 "$pidout"
    local holder_pgid; holder_pgid=$(cat "$pidout")
    # The informational PIDFILE names the holder's REAL process group.
    printf 'pgid=%s start=%s session=other\n' "$holder_pgid" "$(date +%s)" >"$(pidfile_for push)"

    stub pr_rollup 0 "1"
    stub pr_checks 0 "ok"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI passed for feat-x" "$output"
    # The holder really is gone — eviction, not a coincidence.
    run kill -0 -- -"$holder_pgid"
    [ "$status" -ne 0 ] || { echo "holder pgid $holder_pgid survived eviction" >&2; return 1; }
}

@test "contention with a missing PIDFILE falls back to lock-probe-only and still acquires" {
    local lock; lock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    # Holder exits on its own well inside CI_WATCH_NO_PID_WAIT.
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
    # A pgid that names nothing: signalling it is a no-op, so the lock probe --
    # the only authority -- is what carries the acquire.
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
    # No PIDFILE and a short probe window: nothing to signal, holder never ends.
    rm -f "$(pidfile_for push)"
    export CI_WATCH_NO_PID_WAIT=1

    run bash "$WATCHER" push "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "Could not acquire lock for feat-x" "$output"
}

@test "push and merge watchers for one branch use different locks and never contend" {
    local pushlock; pushlock=$(lockfile_for push)
    local pidout="$BATS_TEST_TMPDIR/holderpid"
    start_lock_holder "$pushlock" 120 "$pidout"

    # A merge watcher runs to completion while the push lock stays held.
    stub pr_state 0 "CLOSED "
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "PR for feat-x closed without merging" "$output"
    run lockf -t 0 -k "$pushlock" true
    assert_eq 75 "$status"
}

# --- run_watchable ----------------------------------------------------------

# Build a driver that sources run_watchable VERBATIM out of the shipped script.
make_run_watchable_driver() {
    {
        echo 'set -m'
        sed -n '/^run_watchable() {$/,/^}$/p' "$WATCHER"
        cat
    } >"$BATS_TEST_TMPDIR/rwdrv.sh"
}

# A stand-in for `gh`: spawns its own child, then blocks. Killing only the
# direct child would leave the grandchild running.
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

# Launch the driver, wait for the fake gh's child, signal the driver, and
# report the observed rc plus whether the whole tree died.
run_watchable_signal_case() {
    local signal="$1"
    make_fake_gh_with_child
    make_run_watchable_driver <<DRV
run_watchable "$BATS_TEST_TMPDIR/fakegh.sh" "$BATS_TEST_TMPDIR/child.pid" "$BATS_TEST_TMPDIR/gh.pid"
printf '%s' "\$?" >"$BATS_TEST_TMPDIR/rc"
DRV
    # Job control MUST be on in THIS shell to launch the driver. Without it a
    # backgrounded child inherits SIGINT/SIGQUIT as SIG_IGN, and bash cannot
    # trap a signal that was already ignored on entry — so the driver's INT
    # trap would never fire and the INT case would hang for a reason that has
    # nothing to do with run_watchable. `set -m` gives the driver its own
    # process group with default signal dispositions, which is exactly how the
    # real watcher runs (the script sets -m itself).
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

# No SIGINT test: run_watchable only traps TERM. Nothing in this system ever
# sends a watcher SIGINT (eviction uses TERM then KILL), and a signal that is
# SIG_IGN "on entry" to a shell can never be
# trapped by it (POSIX/bash) — the disposition a background job gets unless
# its parent enables real job control before forking it, which a backgrounded
# Bash-tool invocation with no controlling terminal cannot guarantee. That
# would be testing an environment property, not this function's logic.

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

# --- push mode --------------------------------------------------------------

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
    # Never even asked gh pr checks: the grace loop is the whole verdict here.
    assert_eq 0 "$(call_count 'pr checks')"
}

@test "push: a genuine check failure reports FAILED and still exits 0" {
    stub pr_rollup 0 "3"
    stub pr_checks 1 "X  build  1m  failing"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI FAILED for feat-x" "$output"
    # Terminal, not retryable: exactly one attempt.
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

@test "push: 'no checks reported' from gh pr checks maps to the no-checks outcome" {
    stub pr_rollup 0 "1"
    stub pr_checks 1 "no checks reported on the 'feat-x' branch"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "No CI checks configured for feat-x" "$output"
    assert_not_contains "CI FAILED" "$output"
}

# --- merge mode, phase 1 ----------------------------------------------------

@test "merge: an already-merged PR goes straight to the post-merge phase" {
    stub pr_state 0 "MERGED deadbeef"
    stub repo_default 0 "main"
    stub run_list 0 "111"
    stub run_watch 0 "ok"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI passed for the merge of feat-x (run 111)" "$output"
    # One poll only: no waiting on an already-merged PR.
    assert_eq 1 "$(call_count 'pr view')"
}

@test "merge: a PR closed without merging is reported and never treated as an error" {
    stub pr_state 0 "CLOSED "
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "PR for feat-x closed without merging" "$output"
    assert_not_contains "persistent error" "$output"
    assert_eq 1 "$(call_count 'pr view')"
    assert_eq 0 "$(call_count 'run list')"
}

@test "merge: a PR merged mid-wait is picked up on a later poll" {
    stub pr_state.1 0 "OPEN "
    stub pr_state.2 0 "MERGED cafe1234"
    stub repo_default 0 "main"
    stub run_list 0 "222"
    stub run_watch 0 "ok"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI passed for the merge of feat-x (run 222)" "$output"
}

@test "merge: a PR still open at MERGE_WAIT_MAX times out with the retry instruction" {
    export CI_WATCH_MERGE_WAIT_MAX=0
    stub pr_state 0 "OPEN "
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "CI settled wait timed out; feat-x still not merged after 6h" "$output"
    assert_contains "Run \`bash $WATCHER_ABS merge feat-x\` after you merge it." "$output"
}

# --- merge mode, phase 2 ----------------------------------------------------

@test "merge: a post-merge run that appears mid-grace is watched, not declared missing" {
    stub pr_state 0 "MERGED abc123"
    stub repo_default 0 "main"
    stub run_list.1 0
    stub run_list.2 0 "333"
    stub run_watch 0 "ok"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI passed for the merge of feat-x (run 333)" "$output"
    assert_not_contains "no post-merge CI run started" "$output"
}

@test "merge: no post-merge run inside the appearance grace is announced as such" {
    export CI_WATCH_RUN_APPEAR_MAX=0
    stub pr_state 0 "MERGED abc123"
    stub repo_default 0 "main"
    stub run_list 0
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "PR merged; no post-merge CI run started on main within 2 min" "$output"
}

@test "merge: a failing post-merge run is announced as FAILED, exit still 0" {
    stub pr_state 0 "MERGED abc123"
    stub repo_default 0 "main"
    stub run_list 0 "444"
    stub run_watch 1 "run failed"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_contains "Post-merge CI FAILED for the merge of feat-x (run 444)" "$output"
}

@test "merge: three discovered runs produce exactly three distinct announce lines" {
    stub pr_state 0 "MERGED abc123"
    stub repo_default 0 "main"
    # The duplicate id proves the in-memory dedup, not just the line count.
    stub run_list 0 "11" "22" "33" "22"
    stub run_watch 0 "ok"
    run bash "$WATCHER" merge "$BRANCH"
    assert_eq 0 "$status"
    assert_eq 3 "$(printf '%s\n' "$output" | grep -c 'Post-merge CI')"
    assert_contains "(run 11)" "$output"
    assert_contains "(run 22)" "$output"
    assert_contains "(run 33)" "$output"
    assert_eq 3 "$(call_count 'run watch')"
}

# --- error classification ---------------------------------------------------

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
}

# --- log discipline ---------------------------------------------------------

@test "gh chatter goes to the per-key log, never to stdout" {
    stub pr_rollup 0 "1"
    stub pr_checks 0 "VERBOSE-GH-CHATTER"
    run bash "$WATCHER" push "$BRANCH"
    assert_eq 0 "$status"
    assert_eq "CI passed for feat-x" "$output"
    run cat "$BATS_TEST_TMPDIR/ci_watch2_push_${SLUG}-${KEY}.log"
    assert_contains "VERBOSE-GH-CHATTER" "$output"
}

# --- self-referencing paths --------------------------------------------------
# This script is meant to be symlinked into another tool's config directory
# (e.g. ~/.pi) rather than copied. Its retry messages must report the path it
# was actually INVOKED through, not the real file's location, so a `.pi` user
# is told to re-run the `.pi` path, not a `.claude` one.

@test "the persistent-error retry message reports the invoked symlink path, not the real file's" {
    LINK_DIR="$BATS_TEST_TMPDIR/pi-style-link"
    mkdir -p "$LINK_DIR"
    ln -s "$WATCHER_ABS" "$LINK_DIR/ci_watch_once.sh"
    ln -s "$(cd "$(dirname "$NOTIFY_SH")" && pwd)/_notify.sh" "$LINK_DIR/_notify.sh"

    stub pr_rollup 1 "gh: Bad credentials (HTTP 401)"
    run bash "$LINK_DIR/ci_watch_once.sh" push "$BRANCH"
    [ "$status" -ne 0 ] || { echo "expected a nonzero exit" >&2; return 1; }
    assert_contains "run \`bash $LINK_DIR/ci_watch_once.sh push feat-x\` to retry" "$output"
    assert_not_contains "$WATCHER_ABS" "$output"
}
