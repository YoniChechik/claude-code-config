#!/usr/bin/env bash
#
# One-shot GitHub Actions monitor.  Usage:
#   gh_monitor.sh push  '<branch>'                       [--repo owner/repo]
#   gh_monitor.sh merge '<branch|PR>'                     [--repo owner/repo]
#   gh_monitor.sh run   '<run-id>'                        [--repo owner/repo]
#   gh_monitor.sh run   '<workflow-file>' --dispatch [--ref <ref>] [-f k=v ...] [--repo owner/repo]
#
# Three design invariants this file exists to uphold:
#
# 1. ONE RUN, ONE REPORT.  The script runs exactly once, start to finish, in one
#    uninterrupted process, and prints exactly one (or, for several post-merge
#    runs, one per run) notification line on stdout before exiting.  There is no
#    re-arm, no phase-cursor file and no duplicate-notification bookkeeping —
#    that entire class of bug is gone by construction, not suppressed by a
#    checkpoint file.  Stdout is reserved for those notification lines ALONE;
#    every gh/git diagnostic goes to LOGFILE.
#
# 2. EVERY BLOCKING CHILD GOES THROUGH run_watchable.  Both gh --watch calls and
#    every poll-loop sleep.  That is what makes a SIGTERM honored within ~1s
#    even in the middle of `gh pr checks --watch`, and makes it reach the whole
#    process group (gh AND gh's own children), not just one PID.
#
# 3. LOCKING IS ENTIRELY lockf/KERNEL-MEDIATED.  The watcher body runs AS the
#    `command` argument of `lockf -t 0 -k`, so the kernel lock's lifetime is
#    exactly the watcher's working lifetime and is released automatically the
#    instant the holder dies by ANY means.  PIDFILE is PURELY INFORMATIONAL: it
#    only aims an eviction signal.  It is never the source of truth for whether
#    the lock is held — a stale, wrong or missing PIDFILE costs at worst a
#    wasted or missing signal, never a lock-safety violation.
#
# MODES
# -----
# push:  watches an open PR's CI checks (the PR belonging to the given branch)
#        to a single terminal verdict.
# merge: waits for the given PR to actually merge, then watches whatever
#        post-merge run(s) that merge triggered on the default branch.
# run:   watches one GitHub Actions workflow run to completion and reports
#        pass/fail (plus which jobs failed, on a failure). Two shapes:
#          - `run <run-id>`                     — an already-dispatched run;
#            just watch it.
#          - `run <workflow-file> --dispatch …` — dispatch a fresh run via
#            `gh workflow run`, resolve the run id it created, then watch it
#            exactly like the first shape.

# Job control, needed twice over:
#   - in the outer driver, so the `lockf` foreground job (and the watcher body
#     under it) lands in its OWN process group, which the body records in
#     PIDFILE as the eviction target;
#   - in the body, so each run_watchable background job lands in its own group,
#     which is what one `kill -TERM -- -<pgid>` can sweep whole.
set -m
set -uo pipefail

# Nothing here reads stdin, and a foreground job in a non-terminal-owning
# process group that touches the tty would take a SIGTTIN.  Close that off.
exec </dev/null

# --- Tunables ---------------------------------------------------------------
# Every wait/poll/timeout below is env-overridable so the test suite runs in
# milliseconds instead of really waiting 45s / 6h / 2min.
: "${GH_MONITOR_CHECK_GRACE_MAX:=45}"    # push/run: registration-grace bound
: "${GH_MONITOR_CHECK_GRACE_POLL:=5}"    # push/run: grace poll interval
: "${GH_MONITOR_MERGE_WAIT_MAX:=21600}"  # merge phase 1: 6h merge-wait bound
: "${GH_MONITOR_MERGE_POLL:=20}"         # merge phase 1: poll interval
: "${GH_MONITOR_RUN_APPEAR_MAX:=120}"    # merge phase 2 / run --dispatch: run-appearance grace
: "${GH_MONITOR_RUN_APPEAR_POLL:=10}"    # merge phase 2 / run --dispatch: poll interval
: "${GH_MONITOR_RETRY_MAX:=3}"           # retryable-error local retries
: "${GH_MONITOR_RETRY_BACKOFF:=5}"       # retryable-error fixed backoff
: "${GH_MONITOR_ACQUIRE_ATTEMPTS:=5}"    # total acquire attempts before giving up
: "${GH_MONITOR_EVICT_TERM_WAIT:=10}"    # lock-probe window after SIGTERM
: "${GH_MONITOR_EVICT_KILL_WAIT:=5}"     # lock-probe window after SIGKILL
: "${GH_MONITOR_NO_PID_WAIT:=30}"        # lock-probe window with no PIDFILE target
: "${GH_MONITOR_PROBE_POLL:=1}"          # lock-probe interval

# /tmp by default; redirected wholesale by the tests.  Shared with _notify.sh.
: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

# _gh_monitor_slug / _gh_monitor_key live in _notify.sh — THE single
# implementation of the slug and key recipes.  Resolved relative to this
# script so the worktree copy and the installed ~/.claude copy each source
# their own sibling.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./_notify.sh
source "${SCRIPT_DIR}/_notify.sh"

# --- run_watchable ----------------------------------------------------------
# Run "$@" as a background job in its OWN process group, block until it ends,
# and stay killable the whole time.
#
# Shape notes, because each line closes a real race:
#   - The trap is installed BEFORE "$@" is backgrounded, so a signal arriving
#     in that gap cannot fall through to the shell's default action.
#   - Only SIGTERM is trapped. The only path that stops a watcher in this
#     system — lock eviction — sends TERM then, if needed, KILL; nothing in
#     this design ever sends SIGINT to a watcher. A SIGINT trap was
#     tried and dropped: a signal that is SIG_IGN "on entry" to a shell can
#     never be trapped by that shell (POSIX/bash rule), which is exactly the
#     disposition a background job gets unless the PARENT shell enables real
#     job control before forking it — a guarantee this script's own caller
#     (a backgrounded Bash-tool invocation, no controlling terminal) cannot
#     make. Chasing that guarantee tests an environment property we don't
#     control, not our own logic, for a signal nothing here ever sends.
#   - `wait` is NOT a reliable thing to poll on here: `sleep` is far more
#     consistently interruptible by a trapped signal across bash versions, so
#     it is the poll primitive. `wait` is only ever called once we already
#     know (via `kill -0`) that the job is truly gone, purely to reap it and
#     read its real exit status.
#   - After the poll loop exits on a caught signal, we poll again (bounded,
#     5x1s) for the group to actually disappear before declaring done, and
#     escalate to SIGKILL on the group if it has not.
#   - The return value distinguishes two genuinely different outcomes: the
#     watched command's own real exit code (nothing interrupted it), or 143
#     (we sent TERM). Never one hardcoded value regardless of cause.
#
# Call it as `run_watchable gh pr checks "$b" --watch >"$OUT" 2>&1; rc=$?` —
# redirections apply to the whole invocation and the child inherits them.
run_watchable() {
    local sig=""
    trap 'sig=TERM; kill -TERM -- "-$watch_pgid" 2>/dev/null' TERM
    "$@" &
    watch_pgid=$!
    local rc=""
    while [[ -z "$rc" ]]; do
        if ! kill -0 "$watch_pgid" 2>/dev/null; then
            wait "$watch_pgid" 2>/dev/null
            rc=$?
            break
        fi
        if [[ -n "$sig" ]]; then
            rc=0  # placeholder; overwritten below by the signalled-return path
            break
        fi
        sleep 0.2
    done
    trap - TERM
    if [[ -n "$sig" ]]; then
        for _ in 1 2 3 4 5; do
            kill -0 -- "-$watch_pgid" 2>/dev/null || break
            sleep 1
        done
        kill -0 -- "-$watch_pgid" 2>/dev/null && kill -KILL -- "-$watch_pgid" 2>/dev/null
        wait "$watch_pgid" 2>/dev/null
        return 143
    fi
    return "$rc"
}

# run_watchable reported that WE were signaled (an eviction by a newer
# watcher).  Leave immediately and silently: the notification of
# this watch's result is now the newer watcher's job, and printing anything
# here would be a second, contradictory report.
bail_if_signaled() {
    case "$1" in
        143 | 130)
            log "signaled (rc=$1) — exiting without reporting"
            exit "$1"
            ;;
    esac
}

# --- Logging ----------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOGFILE" 2>/dev/null || true; }

# --- gh/git call wrapper ----------------------------------------------------
# Runs one gh/git call through run_watchable, captures ITS OWN output into a
# fresh mktemp file, classifies THAT text, then appends it to LOGFILE.  Never
# classify by grepping a shared log tail: it could still hold a previous
# invocation's leftover text and turn a success into a phantom failure.
#
# Sets GH_OUT to the captured text and returns the command's real exit code.
# A retryable failure (auth, rate limit, transient network, call timeout) is
# retried up to GH_MONITOR_RETRY_MAX times with a fixed GH_MONITOR_RETRY_BACKOFF;
# on exhaustion it calls die_persistent and never returns.  A TERMINAL result —
# including a genuine CI failure or a closed PR — is handed straight back to the
# caller and is never reinterpreted as an error.
#
# GH_TERMINAL_RC is a space-separated list of exit codes that this particular
# call site declares ALWAYS terminal, checked before any text matching.  Both
# `gh pr checks --watch` and `gh run watch --exit-status` use exit 1 to mean
# "CI is red", and their output lists CI job names — a job named "timeout-probe"
# must never be read as a transient timeout and retried into a false pass.
GH_OUT=""
gh_call() {
    local attempt=1 out rc
    local terminal_rc="${GH_TERMINAL_RC:-}"
    while :; do
        out=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_call.XXXXXX") || {
            die_persistent "could not create a temp file"
        }
        # </dev/null: the child must never eat the caller's stdin (phase 2 reads
        # the run-id list with a `while read` loop wrapped around this call).
        run_watchable "$@" >"$out" 2>&1 </dev/null
        rc=$?
        GH_OUT=$(cat "$out" 2>/dev/null)
        log "\$ $* -> rc=$rc"
        cat "$out" >>"$LOGFILE" 2>/dev/null
        rm -f "$out"
        bail_if_signaled "$rc"

        # Success, a caller-declared terminal code, or a failure that carries no
        # transient signature, is the real answer.  Hand it back untouched.
        if [[ "$rc" -eq 0 ]]; then
            return 0
        fi
        case " $terminal_rc " in
            *" $rc "*) return "$rc" ;;
        esac
        if ! is_retryable "$rc" "$GH_OUT"; then
            return "$rc"
        fi
        if [[ "$attempt" -ge "$GH_MONITOR_RETRY_MAX" ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        log "retryable error (attempt ${attempt}/${GH_MONITOR_RETRY_MAX}); backing off ${GH_MONITOR_RETRY_BACKOFF}s"
        attempt=$((attempt + 1))
        run_watchable sleep "$GH_MONITOR_RETRY_BACKOFF"
        bail_if_signaled $?
    done
}

# Same as gh_call, but the call is expected to yield non-empty text (a -q
# projection of a --json result).  An empty or whitespace-only body from an
# otherwise-successful call means malformed/empty JSON, which is retryable —
# treating it as a real answer is exactly how a transient blip becomes a false
# "no checks"/"no runs" verdict.
gh_call_nonempty() {
    local attempt=1 rc
    while :; do
        gh_call "$@"
        rc=$?
        if [[ "$rc" -eq 0 && -n "${GH_OUT//[[:space:]]/}" ]]; then
            return 0
        fi
        if [[ "$rc" -ne 0 ]]; then
            return "$rc"
        fi
        if [[ "$attempt" -ge "$GH_MONITOR_RETRY_MAX" ]]; then
            die_persistent "empty or malformed JSON from gh"
        fi
        log "empty response (attempt ${attempt}/${GH_MONITOR_RETRY_MAX}); backing off"
        attempt=$((attempt + 1))
        run_watchable sleep "$GH_MONITOR_RETRY_BACKOFF"
        bail_if_signaled $?
    done
}

# A best-effort gh call that must NEVER escalate to die_persistent: used only
# for embellishing an already-known verdict (e.g. the per-job failure list
# after `gh run watch` already returned a real pass/fail). Still routed
# through run_watchable for signal-safety, still logged, but a failure here
# just means the embellishment is missing — the caller falls back to the
# plain verdict it already has. Sets GH_OUT; returns the command's exit code
# with no retry of any kind.
gh_call_best_effort() {
    local out rc
    out=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_call.XXXXXX") || {
        GH_OUT=""
        return 1
    }
    run_watchable "$@" >"$out" 2>&1 </dev/null
    rc=$?
    GH_OUT=$(cat "$out" 2>/dev/null)
    log "\$ $* -> rc=$rc (best-effort)"
    cat "$out" >>"$LOGFILE" 2>/dev/null
    rm -f "$out"
    bail_if_signaled "$rc"
    return "$rc"
}

# Is this (exit code, output) pair a transient error worth retrying, as opposed
# to a real reportable outcome?  Matched case-insensitively on the call's OWN
# captured text.
is_retryable() {
    local rc="$1" text="$2"
    # 124 is `timeout`'s "the call itself timed out"; 125-127 mean the command
    # could not be started, which on a transient FS/PATH hiccup is worth a retry.
    case "$rc" in 124 | 125 | 126 | 127) return 0 ;; esac
    shopt -s nocasematch
    local hit=1
    if [[ "$text" =~ (HTTP\ 401|HTTP\ 403|HTTP\ 429|HTTP\ 5[0-9][0-9]|rate\ limit|secondary\ rate|bad\ credentials|authentication\ failed|not\ logged\ into|gh\ auth\ login|could\ not\ resolve\ host|connection\ refused|connection\ reset|network\ is\ unreachable|no\ route\ to\ host|i/o\ timeout|timed\ out|timeout|tls\ handshake|eof|temporary\ failure|server\ error|service\ unavailable|try\ again) ]]; then
        hit=0
    fi
    shopt -u nocasematch
    return "$hit"
}

# First non-empty line of the captured output, capped, for the user-facing
# "persistent error" line.  The full text is already in LOGFILE.
short_reason() {
    local line
    line=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -n 1)
    line=${line:0:120}
    printf '%s' "${line:-unknown error}"
}

# The one escalation path out of a retryable error: one stdout line, nonzero
# exit.  A watcher that cannot see the truth must say so, never guess.
# RETRY_EXTRA (set once near the entry point) reproduces any `run --dispatch`
# flags the original invocation carried, so the printed retry command is
# actually runnable rather than silently dropping how the target was reached.
die_persistent() {
    printf 'CI watch for %s hit a persistent error: %s — stopping; run `bash %s %s %s%s` to retry\n' \
        "$TARGET" "$1" "$SELF" "$MODE" "$TARGET" "${RETRY_EXTRA:-}"
    exit 1
}

# --- PIDFILE ----------------------------------------------------------------
# Atomic mktemp-then-mv, this repo's convention for every /tmp sidecar: a
# concurrent reader must never observe a half-written file.  The temp name is
# per-invocation unique and deliberately does NOT start with "gh_monitor_pid_",
# so no glob over the real prefix can ever enumerate a temp file as a watcher.
write_pidfile() {
    local pgid tmp
    # Our OWN process group.  NOT $$: `set -m` in a non-interactive shell does
    # not make the shell a group leader — it only gives each JOB a new group.
    # We are that job (the driver ran us as a foreground `lockf`), so our pgid
    # comes from ps, and it is the group an evictor must signal to reach us,
    # the lockf holding the fd, and every gh child under us.
    pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    [[ -n "$pgid" ]] || return 0
    tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_tmp_pid.XXXXXX") || return 0
    if ! printf 'pgid=%s start=%s session=%s\n' \
        "$pgid" "$(date +%s)" "${CLAUDE_CODE_SESSION_ID:-}" >"$tmp" \
        || ! mv -f "$tmp" "$PIDFILE"; then
        rm -f "$tmp"
        log "warning: could not write $PIDFILE (eviction signals cannot be aimed at us)"
    fi
    return 0
}

# Echo the recorded holder's pgid, or nothing.  Purely a signal target; a wrong
# or missing value degrades to "poll the lock and wait", never to a lock-safety
# violation, because the kernel remains the sole arbiter of who holds the lock.
read_pidfile_pgid() {
    [[ -f "$PIDFILE" ]] || return 0
    local field
    field=$(head -c 256 "$PIDFILE" 2>/dev/null | tr ' ' '\n' | grep '^pgid=' | head -n 1)
    field=${field#pgid=}
    case "$field" in
        '' | *[!0-9]*) return 0 ;;
        *) printf '%s' "$field" ;;
    esac
}

# --- Lock probing -----------------------------------------------------------
# Poll the LOCK ITSELF for up to $1 seconds.  The lock actually clearing is the
# ONLY authoritative signal that eviction worked — never a guess about whether
# some (possibly reused) pgid is still alive.  `lockf -t 0 -k ... true` costs
# one fork and leaves the lock file in place for the next acquirer.
probe_lock_free() {
    local deadline=$(($(date +%s) + $1))
    while :; do
        if lockf -t 0 -k "$LOCKFILE" true 2>/dev/null; then
            return 0
        fi
        [[ "$(date +%s)" -ge "$deadline" ]] && return 1
        sleep "$GH_MONITOR_PROBE_POLL"
    done
}

# --- Per-job breakdown (run mode) --------------------------------------------
# Best-effort embellishment: a comma-separated list of job names that did NOT
# conclude "success" for the given run id, or empty on any failure to fetch
# it. Never affects the real pass/fail verdict, which always comes from
# `gh run watch --exit-status`'s own exit code.
failed_jobs_for() {
    local run_id="$1"
    if gh_call_best_effort gh run view "$run_id" --repo "$OWNER_REPO" --json jobs \
        -q '[.jobs[] | select(.conclusion != null and .conclusion != "success") | .name] | join(", ")'; then
        printf '%s' "$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r')"
    fi
}

# Last non-empty line of a captured gh output.
last_line() {
    printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r'
}

# True when the output ENDS with gh's own request/transport error (as opposed to
# a check row): `Post "https://api.github.com/graphql": ... timed out`, or
# `HTTP 502: ...`.  Anchored to the line start so a CI job name can't match.
is_gh_transport_error() {
    local line
    line=$(last_line "$1")
    [[ "$line" =~ ^((Post|Get|Put|Patch|Delete)\ \"https?://|HTTP\ [0-9]{3}) ]] || return 1
    is_retryable 1 "$line"
}

# --- Watcher bodies ---------------------------------------------------------

# push mode.  Ends at the first real CI verdict for this branch's PR.
push_body() {
    local waited=0 rc

    # Step 1: check-registration grace.  Right after a push or `gh pr create`,
    # GitHub may not have registered the check suites yet, so an immediate "no
    # checks" is a lie a few seconds early.  Poll the rollup first, and only
    # believe "none" once the whole grace window has passed.
    while :; do
        gh_call_nonempty gh pr view "$TARGET" --repo "$OWNER_REPO" --json statusCheckRollup \
            -q '.statusCheckRollup | length'
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        local count=${GH_OUT//[[:space:]]/}
        case "$count" in
            '' | *[!0-9]*) count=0 ;;
        esac
        if [[ "$count" -gt 0 ]]; then
            log "rollup has ${count} check(s) after ${waited}s — watching"
            break
        fi
        if [[ "$waited" -ge "$GH_MONITOR_CHECK_GRACE_MAX" ]]; then
            printf 'No CI checks configured for %s\n' "$TARGET"
            return 0
        fi
        run_watchable sleep "$GH_MONITOR_CHECK_GRACE_POLL"
        bail_if_signaled $?
        waited=$((waited + GH_MONITOR_CHECK_GRACE_POLL))
    done

    # Step 2: block on the real verdict.
    #
    # Deliberately NOT --fail-fast. `--fail-fast` returns the instant ANY
    # single check goes red, which races against a transient-failure re-run —
    # and this watcher is ONE RUN, ONE REPORT with no re-arm (see the file
    # header), so a stale "CI FAILED" from a flake that was re-run and passed
    # a moment later is final: nobody ever tells the caller the real outcome.
    # Confirmed in production 2026-09-21: a WIF-token-refresh flake on
    # `app-backend-integration-tests` tripped --fail-fast at the instant it
    # went red; the calling agent recognized it as transient and re-ran the
    # job, which passed — but the watcher had already reported "CI FAILED"
    # and exited, so the PR sat fully green and unmerged with no watcher left
    # to say so. Without --fail-fast, `gh pr checks --watch` polls the whole
    # rollup until every check reaches a terminal state, so a check that gets
    # re-run while still polling has its NEW result picked up on the next
    # poll instead of being missed. This costs a slower report on a real,
    # non-flaky failure (no other check can shortcut a doomed run early) in
    # exchange for never reporting a stale false failure on a flake.
    #
    # `gh pr checks` exits 1 for BOTH "a check failed" AND "gh itself died" (a
    # dropped connection mid-`--watch` prints a Go net error as the last line
    # and exits 1).  Exit 1 is declared terminal so a failing job NAME like
    # "timeout-probe" is never text-matched into a retry, but that also turned a
    # transport error into "CI FAILED" while every check was green or still
    # pending (2026-10-03, PRs 3701/3703).  So classify only the LAST line: if
    # gh's own error text is there, re-arm the watch (bounded); a real verdict
    # ends with a check row instead.
    local watch_attempt=1
    while :; do
        GH_TERMINAL_RC=1 gh_call gh pr checks "$TARGET" --repo "$OWNER_REPO" --watch
        rc=$?
        [[ "$rc" -eq 0 ]] && break
        is_gh_transport_error "$GH_OUT" || break
        if [[ "$watch_attempt" -ge "$GH_MONITOR_RETRY_MAX" ]]; then
            die_persistent "$(short_reason "$(last_line "$GH_OUT")")"
        fi
        log "gh pr checks --watch died on a transport error (attempt ${watch_attempt}/${GH_MONITOR_RETRY_MAX}); re-arming"
        watch_attempt=$((watch_attempt + 1))
        run_watchable sleep "$GH_MONITOR_RETRY_BACKOFF"
        bail_if_signaled $?
    done
    if [[ "$rc" -eq 0 ]]; then
        printf 'CI passed for %s\n' "$TARGET"
        return 0
    fi
    # `gh pr checks` shares exit 1 between "genuinely failed" and "no checks
    # reported".  Step 1's grace loop already ruled out the latter unless the
    # checks vanished under us, so only the literal text can still claim it.
    case "$GH_OUT" in
        *"no checks reported"*)
            printf 'No CI checks configured for %s\n' "$TARGET"
            return 0
            ;;
    esac
    # Reporting a red CI is the watcher's job DONE, not the watcher failing:
    # exit 0.
    printf 'CI FAILED for %s\n' "$TARGET"
    return 0
}

# merge mode.  Phase 1 waits for the merge, phase 2 watches what the merge
# triggered on the default branch.
merge_body() {
    local wait_start sha state field rc
    wait_start=$(date +%s)

    # Phase 1: merge-wait.  `gh pr merge --auto` returns success long before the
    # PR is really merged, so the merge itself is what we poll for — bounded, so
    # a forgotten watcher has a concrete lifetime instead of living forever.
    while :; do
        gh_call_nonempty gh pr view "$TARGET" --repo "$OWNER_REPO" \
            --json state,mergedAt,mergeCommit,url \
            -q '(.state) + " " + (.mergeCommit.oid // "")'
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        field=$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1)
        state=${field%% *}
        sha=${field#* }
        sha=${sha//[[:space:]]/}
        case "$state" in
            MERGED)
                log "PR merged, commit=${sha:-<unknown>}"
                break
                ;;
            CLOSED)
                printf 'PR for %s closed without merging\n' "$TARGET"
                return 0
                ;;
        esac
        if [[ $(($(date +%s) - wait_start)) -ge "$GH_MONITOR_MERGE_WAIT_MAX" ]]; then
            printf 'CI settled wait timed out; %s still not merged after 6h — stopping. Run `bash %s merge %s` after you merge it.\n' \
                "$TARGET" "$SELF" "$TARGET"
            return 0
        fi
        run_watchable sleep "$GH_MONITOR_MERGE_POLL"
        bail_if_signaled $?
    done

    # Phase 2: find the post-merge run(s) on the default branch, then watch each.
    if ! gh_call_nonempty gh repo view "$OWNER_REPO" --json defaultBranchRef -q .defaultBranchRef.name; then
        die_persistent "$(short_reason "$GH_OUT")"
    fi
    local default_branch
    default_branch=$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1)
    default_branch=${default_branch//[[:space:]]/}

    # Appearance grace, same false-negative concern as the check-registration
    # race but on a shorter fuse: post-merge runs normally register within
    # seconds of the merge commit landing.
    local appeared=0 waited=0 ids_text=""
    while :; do
        if gh_call gh run list --repo "$OWNER_REPO" --branch "$default_branch" --commit "$sha" \
            --json databaseId -L 20 -q '.[].databaseId' \
            && [[ -n "${GH_OUT//[[:space:]]/}" ]]; then
            ids_text=$GH_OUT
            appeared=1
            break
        fi
        if [[ "$waited" -ge "$GH_MONITOR_RUN_APPEAR_MAX" ]]; then
            break
        fi
        run_watchable sleep "$GH_MONITOR_RUN_APPEAR_POLL"
        bail_if_signaled $?
        waited=$((waited + GH_MONITOR_RUN_APPEAR_POLL))
    done
    if [[ "$appeared" -eq 0 ]]; then
        printf 'PR merged; no post-merge CI run started on %s within 2 min\n' "$default_branch"
        return 0
    fi

    # ONE snapshot, taken here and never re-polled.  A run that registers after
    # this point, or a fan-out past 20, is an accepted scope limit.  Dedup is a
    # plain in-memory array: this process never restarts, so no durable file is
    # needed to know what has already been announced.
    local seen=() id announced
    while read -r id; do
        id=${id//[[:space:]]/}
        [[ -n "$id" ]] || continue
        announced=0
        local s
        for s in ${seen[@]+"${seen[@]}"}; do
            [[ "$s" == "$id" ]] && announced=1 && break
        done
        [[ "$announced" -eq 1 ]] && continue
        seen+=("$id")

        if GH_TERMINAL_RC=1 gh_call gh run watch "$id" --repo "$OWNER_REPO" --exit-status; then
            printf 'Post-merge CI passed for the merge of %s (run %s)\n' "$TARGET" "$id"
        else
            printf 'Post-merge CI FAILED for the merge of %s (run %s)\n' "$TARGET" "$id"
        fi
    done <<<"$ids_text"

    # Every discovered run has been announced.  Exit 0 whatever the verdicts
    # were — reporting them IS the successful job.
    return 0
}

# run mode.  Either watches an already-dispatched run id, or (with
# RUN_DISPATCH=1) dispatches a fresh run via `gh workflow run` first and
# resolves the run id that created before watching it. Ends at the first real
# pass/fail verdict for that one run, with a best-effort per-job failure list
# on a red verdict.
run_body() {
    local run_id rc

    if [[ "$RUN_DISPATCH" -eq 1 ]]; then
        # Phase 1: dispatch. `gh workflow run` itself reports no run id, so the
        # dispatch timestamp (taken BEFORE the call) is what phase 2 uses to
        # pick the right new run out of the workflow's run list.
        local dispatch_args=(gh workflow run "$TARGET" --repo "$OWNER_REPO")
        [[ -n "$RUN_REF" ]] && dispatch_args+=(--ref "$RUN_REF")
        local field
        for field in "${RUN_FIELDS[@]:-}"; do
            [[ -n "$field" ]] && dispatch_args+=(-f "$field")
        done
        gh_call "${dispatch_args[@]}"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        local dispatch_time
        dispatch_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        log "dispatched workflow ${TARGET} at ${dispatch_time}"

        # Phase 2: appearance grace. Same false-negative concern as push's
        # check-registration grace and merge's post-merge appearance grace: the
        # new run normally registers within seconds, but not always instantly.
        local waited=0
        run_id=""
        while :; do
            gh_call gh run list --repo "$OWNER_REPO" --workflow "$TARGET" -L 10 \
                --json databaseId,createdAt \
                -q "[.[] | select(.createdAt >= \"$dispatch_time\")] | sort_by(.createdAt) | .[0].databaseId // empty"
            rc=$?
            if [[ "$rc" -eq 0 ]]; then
                run_id=$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1)
                run_id=${run_id//[[:space:]]/}
                [[ -n "$run_id" ]] && break
            fi
            if [[ "$waited" -ge "$GH_MONITOR_RUN_APPEAR_MAX" ]]; then
                printf 'Dispatched %s on %s but no run appeared within %ss\n' \
                    "$TARGET" "$OWNER_REPO" "$GH_MONITOR_RUN_APPEAR_MAX"
                return 0
            fi
            run_watchable sleep "$GH_MONITOR_RUN_APPEAR_POLL"
            bail_if_signaled $?
            waited=$((waited + GH_MONITOR_RUN_APPEAR_POLL))
        done
        log "resolved dispatched run id=${run_id}"
    else
        # Already-dispatched shape: TARGET IS the run id. Confirm it is
        # actually visible before the (potentially long) watch call, the same
        # "don't believe an early negative" grace push/merge already apply —
        # `gh run watch` on a not-yet-registered id fails with text this
        # script has no business trying to pattern-match as transient.
        run_id="$TARGET"
        local waited=0 seen_run=0
        while :; do
            if gh_call_best_effort gh run view "$run_id" --repo "$OWNER_REPO" --json databaseId; then
                seen_run=1
                break
            fi
            if [[ "$waited" -ge "$GH_MONITOR_CHECK_GRACE_MAX" ]]; then
                break
            fi
            run_watchable sleep "$GH_MONITOR_CHECK_GRACE_POLL"
            bail_if_signaled $?
            waited=$((waited + GH_MONITOR_CHECK_GRACE_POLL))
        done
        if [[ "$seen_run" -eq 0 ]]; then
            printf 'No CI run found for %s on %s\n' "$run_id" "$OWNER_REPO"
            return 0
        fi
    fi

    GH_TERMINAL_RC=1 gh_call gh run watch "$run_id" --repo "$OWNER_REPO" --exit-status
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf 'CI run %s passed for %s\n' "$run_id" "$OWNER_REPO"
        return 0
    fi
    local jobs_line
    jobs_line=$(failed_jobs_for "$run_id")
    if [[ -n "$jobs_line" ]]; then
        printf 'CI run %s FAILED for %s — failed jobs: %s\n' "$run_id" "$OWNER_REPO" "$jobs_line"
    else
        printf 'CI run %s FAILED for %s\n' "$run_id" "$OWNER_REPO"
    fi
    return 0
}

# The watcher body proper: everything that runs WHILE the lock is held.
# Reached only via `lockf`, as its `command` argument, so the kernel lock's
# lifetime is exactly this function's lifetime.
body_dispatch() {
    # We are here, therefore we hold the lock.  Record the eviction target now,
    # before any slow call, so a newer watcher arriving a moment later has
    # something to aim at.
    write_pidfile
    log "acquired lock; mode=${MODE} target=${TARGET} repo=${OWNER_REPO}"
    case "$MODE" in
        push) push_body ;;
        merge) merge_body ;;
        run) run_body ;;
    esac
}

# --- Lock acquire / eviction driver ----------------------------------------
# Runs the real body as `lockf`'s command.  Exit 75 (EX_TEMPFAIL) is the ONLY
# contention signal; any other code is the body's own completed outcome and is
# passed straight out.
acquire_and_run() {
    local attempt rc pgid
    local reentry_args=("$SELF" "$MODE" "$TARGET" "$BODY_SENTINEL")
    [[ -n "$REPO_OVERRIDE" ]] && reentry_args+=(--repo "$REPO_OVERRIDE")
    if [[ "$MODE" == run && "$RUN_DISPATCH" -eq 1 ]]; then
        reentry_args+=(--dispatch)
        [[ -n "$RUN_REF" ]] && reentry_args+=(--ref "$RUN_REF")
        local field
        for field in "${RUN_FIELDS[@]:-}"; do
            [[ -n "$field" ]] && reentry_args+=(-f "$field")
        done
    fi
    for ((attempt = 1; attempt <= GH_MONITOR_ACQUIRE_ATTEMPTS; attempt++)); do
        lockf -t 0 -k "$LOCKFILE" "$BASH" "${reentry_args[@]}"
        rc=$?
        if [[ "$rc" -ne 75 ]]; then
            exit "$rc"
        fi

        log "lock held (attempt ${attempt}/${GH_MONITOR_ACQUIRE_ATTEMPTS}); evicting"
        pgid=$(read_pidfile_pgid)
        if [[ -z "$pgid" ]]; then
            # No recorded target.  A documented residual limitation, not a bug:
            # with nothing to signal, all we can do is wait out the holder.
            log "no usable PIDFILE; lock-probe-only wait up to ${GH_MONITOR_NO_PID_WAIT}s"
            if probe_lock_free "$GH_MONITOR_NO_PID_WAIT"; then
                continue
            fi
            printf 'Could not acquire lock for %s: it is held and no PID file names a process to signal\n' \
                "$TARGET"
            exit 1
        fi

        kill -TERM -- -"$pgid" 2>/dev/null
        probe_lock_free "$GH_MONITOR_EVICT_TERM_WAIT" && continue
        log "pgid ${pgid} did not release within ${GH_MONITOR_EVICT_TERM_WAIT}s; escalating to SIGKILL"
        kill -KILL -- -"$pgid" 2>/dev/null
        probe_lock_free "$GH_MONITOR_EVICT_KILL_WAIT"
    done
    printf 'Could not acquire lock for %s after %d attempts\n' "$TARGET" "$GH_MONITOR_ACQUIRE_ATTEMPTS"
    exit 1
}

# --- Entry point ------------------------------------------------------------
BODY_SENTINEL="__gh_monitor_body"
# Absolute, so the re-entry through `lockf` cannot depend on the driver's cwd.
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

usage() {
    cat >&2 <<'USAGE'
Usage:
  gh_monitor.sh push  '<branch>'                                    [--repo owner/repo]
  gh_monitor.sh merge '<branch|PR>'                                 [--repo owner/repo]
  gh_monitor.sh run   '<run-id>'                                    [--repo owner/repo]
  gh_monitor.sh run   '<workflow-file>' --dispatch [--ref <ref>] [-f key=value ...] [--repo owner/repo]
USAGE
    exit 2
}

MODE="${1:-}"
case "$MODE" in
    push | merge | run) ;;
    *) usage ;;
esac

TARGET="${2:-}"
# Strip leading/trailing whitespace: a pasted branch/run-id/workflow-file with
# a stray space would otherwise hash to a key no other caller ever computes.
TARGET="${TARGET#"${TARGET%%[![:space:]]*}"}"
TARGET="${TARGET%"${TARGET##*[![:space:]]}"}"
[[ -n "$TARGET" ]] || usage
# For merge mode this may also be a bare PR number, a PR URL, or any other
# selector `gh pr view`/`gh pr merge` itself accepts; for run mode it is
# either an already-dispatched numeric run id, or (with --dispatch) a
# workflow file name/id -- the caller (the PostToolUse hook, or whoever
# dispatched the run) trusts an explicit target over guessing one from the
# current branch, and every gh call below already treats this value as an
# opaque selector string, never as something it parses itself.

# --- Remaining args: BODY_SENTINEL, --repo, and (run mode only) --dispatch/
# --ref/-f, order-independent. -----------------------------------------------
# External callers pass MODE TARGET [--repo owner/repo] [run-mode flags]; the
# internal lockf re-entry (acquire_and_run, above) additionally inserts
# BODY_SENTINEL, anywhere among the rest -- every flag is recognized
# regardless of position.
IS_BODY=0
REPO_OVERRIDE=""
RUN_DISPATCH=0
RUN_REF=""
RUN_FIELDS=()
RETRY_EXTRA=""
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        "$BODY_SENTINEL")
            IS_BODY=1
            shift
            ;;
        --repo)
            REPO_OVERRIDE="${2:-}"
            shift 2
            ;;
        --repo=*)
            REPO_OVERRIDE="${1#--repo=}"
            shift
            ;;
        --dispatch)
            [[ "$MODE" == run ]] || usage
            RUN_DISPATCH=1
            shift
            ;;
        --ref)
            [[ "$MODE" == run ]] || usage
            RUN_REF="${2:-}"
            shift 2
            ;;
        --ref=*)
            [[ "$MODE" == run ]] || usage
            RUN_REF="${1#--ref=}"
            shift
            ;;
        -f | --field)
            [[ "$MODE" == run ]] || usage
            RUN_FIELDS+=("${2:-}")
            shift 2
            ;;
        -f=* | --field=*)
            [[ "$MODE" == run ]] || usage
            RUN_FIELDS+=("${1#*=}")
            shift
            ;;
        *)
            # Unrecognized extra argument: ignored defensively rather than
            # failing a re-entry this driver does not fully control the
            # shape of.
            shift
            ;;
    esac
done

# `run` without `--dispatch` never takes --ref/-f -- those only make sense
# alongside a fresh dispatch, and silently accepting them otherwise would
# make a typo'd `--dispatch` look like it still took effect.
if [[ "$MODE" == run && "$RUN_DISPATCH" -eq 0 ]]; then
    [[ -n "$RUN_REF" ]] && usage
    [[ "${#RUN_FIELDS[@]}" -eq 0 ]] || usage
fi

# Reconstruct the exact retry-command suffix for die_persistent, BEFORE any
# gh call can fail -- a dispatch's flags are part of what makes the retry
# command actually runnable, not just its mode and target.
if [[ "$MODE" == run && "$RUN_DISPATCH" -eq 1 ]]; then
    RETRY_EXTRA=" --dispatch"
    [[ -n "$RUN_REF" ]] && RETRY_EXTRA+=" --ref $RUN_REF"
    for field in "${RUN_FIELDS[@]:-}"; do
        [[ -n "$field" ]] && RETRY_EXTRA+=" -f $field"
    done
fi

# The repo every gh call below targets. An explicit --repo is TRUSTED
# outright and used as-is -- the caller named it, so there is nothing to
# verify against this process's own cwd. Otherwise, fall back to resolving it
# from `gh`'s own cwd, exactly as before.
if [[ -n "$REPO_OVERRIDE" ]]; then
    OWNER_REPO="$REPO_OVERRIDE"
else
    OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
    OWNER_REPO=${OWNER_REPO//[[:space:]]/}
    if [[ -z "$OWNER_REPO" ]]; then
        echo "Error: could not resolve owner/repo via gh; cannot key the gh monitor files." >&2
        exit 1
    fi
fi

KEY=$(_gh_monitor_key "$OWNER_REPO" "$TARGET") || exit 1
SLUG=$(_gh_monitor_slug "$TARGET")

# Kind-scoped filenames: a push watcher, a merge watcher and a run watcher for
# the SAME target use different lock files and therefore never contend with
# or evict each other.
LOCKFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_lock_${MODE}_${SLUG}-${KEY}"
PIDFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_pid_${MODE}_${SLUG}-${KEY}"
LOGFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_${MODE}_${SLUG}-${KEY}.log"

# Stdout stays clean for the notification lines.  Everything else — including
# job control's own "[1]+ Done" chatter — goes to the per-key log.
exec 2>>"$LOGFILE"

if [[ "$IS_BODY" -eq 1 ]]; then
    body_dispatch
    exit $?
fi

acquire_and_run
