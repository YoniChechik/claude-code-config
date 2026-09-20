#!/usr/bin/env bash
#
# One-shot CI watcher.  Usage: ci_watch.sh push|merge '<branch>'
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
: "${CI_WATCH_CHECK_GRACE_MAX:=45}"      # push: check-registration grace bound
: "${CI_WATCH_CHECK_GRACE_POLL:=5}"      # push: grace poll interval
: "${CI_WATCH_MERGE_WAIT_MAX:=21600}"    # merge phase 1: 6h merge-wait bound
: "${CI_WATCH_MERGE_POLL:=20}"           # merge phase 1: poll interval
: "${CI_WATCH_RUN_APPEAR_MAX:=120}"      # merge phase 2: run-appearance grace
: "${CI_WATCH_RUN_APPEAR_POLL:=10}"      # merge phase 2: poll interval
: "${CI_WATCH_RETRY_MAX:=3}"             # retryable-error local retries
: "${CI_WATCH_RETRY_BACKOFF:=5}"         # retryable-error fixed backoff
: "${CI_WATCH_ACQUIRE_ATTEMPTS:=5}"      # total acquire attempts before giving up
: "${CI_WATCH_EVICT_TERM_WAIT:=10}"      # lock-probe window after SIGTERM
: "${CI_WATCH_EVICT_KILL_WAIT:=5}"       # lock-probe window after SIGKILL
: "${CI_WATCH_NO_PID_WAIT:=30}"          # lock-probe window with no PIDFILE target
: "${CI_WATCH_PROBE_POLL:=1}"            # lock-probe interval

# /tmp by default; redirected wholesale by the tests.  Shared with _notify.sh.
: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

# _ci_slug / _ci_watch_key live in _notify.sh — THE single implementation of the
# slug and key recipes.  Resolved relative to this script so the worktree copy
# and the installed ~/.claude copy each source their own sibling.
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
# this branch's CI result is now the newer watcher's job, and printing anything
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
# retried up to CI_WATCH_RETRY_MAX times with a fixed CI_WATCH_RETRY_BACKOFF;
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
        out=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.ci_watch2_call.XXXXXX") || {
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
        if [[ "$attempt" -ge "$CI_WATCH_RETRY_MAX" ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        log "retryable error (attempt ${attempt}/${CI_WATCH_RETRY_MAX}); backing off ${CI_WATCH_RETRY_BACKOFF}s"
        attempt=$((attempt + 1))
        run_watchable sleep "$CI_WATCH_RETRY_BACKOFF"
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
        if [[ "$attempt" -ge "$CI_WATCH_RETRY_MAX" ]]; then
            die_persistent "empty or malformed JSON from gh"
        fi
        log "empty response (attempt ${attempt}/${CI_WATCH_RETRY_MAX}); backing off"
        attempt=$((attempt + 1))
        run_watchable sleep "$CI_WATCH_RETRY_BACKOFF"
        bail_if_signaled $?
    done
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
die_persistent() {
    printf 'CI watch for %s hit a persistent error: %s — stopping; run `bash %s %s %s` to retry\n' \
        "$BRANCH" "$1" "$SELF" "$MODE" "$BRANCH"
    exit 1
}

# --- PIDFILE ----------------------------------------------------------------
# Atomic mktemp-then-mv, this repo's convention for every /tmp sidecar: a
# concurrent reader must never observe a half-written file.  The temp name is
# per-invocation unique and deliberately does NOT start with "ci_watch2_pid_",
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
    tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.ci_watch2_tmp_pid.XXXXXX") || return 0
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
        sleep "$CI_WATCH_PROBE_POLL"
    done
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
        gh_call_nonempty gh pr view "$BRANCH" --repo "$OWNER_REPO" --json statusCheckRollup \
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
        if [[ "$waited" -ge "$CI_WATCH_CHECK_GRACE_MAX" ]]; then
            printf 'No CI checks configured for %s\n' "$BRANCH"
            return 0
        fi
        run_watchable sleep "$CI_WATCH_CHECK_GRACE_POLL"
        bail_if_signaled $?
        waited=$((waited + CI_WATCH_CHECK_GRACE_POLL))
    done

    # Step 2: block on the real verdict.
    GH_TERMINAL_RC=1 gh_call gh pr checks "$BRANCH" --repo "$OWNER_REPO" --watch --fail-fast
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf 'CI passed for %s\n' "$BRANCH"
        return 0
    fi
    # `gh pr checks` shares exit 1 between "genuinely failed" and "no checks
    # reported".  Step 1's grace loop already ruled out the latter unless the
    # checks vanished under us, so only the literal text can still claim it.
    case "$GH_OUT" in
        *"no checks reported"*)
            printf 'No CI checks configured for %s\n' "$BRANCH"
            return 0
            ;;
    esac
    # Reporting a red CI is the watcher's job DONE, not the watcher failing:
    # exit 0.
    printf 'CI FAILED for %s\n' "$BRANCH"
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
        gh_call_nonempty gh pr view "$BRANCH" --repo "$OWNER_REPO" \
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
                printf 'PR for %s closed without merging\n' "$BRANCH"
                return 0
                ;;
        esac
        if [[ $(($(date +%s) - wait_start)) -ge "$CI_WATCH_MERGE_WAIT_MAX" ]]; then
            printf 'CI settled wait timed out; %s still not merged after 6h — stopping. Run `bash %s merge %s` after you merge it.\n' \
                "$BRANCH" "$SELF" "$BRANCH"
            return 0
        fi
        run_watchable sleep "$CI_WATCH_MERGE_POLL"
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
        if [[ "$waited" -ge "$CI_WATCH_RUN_APPEAR_MAX" ]]; then
            break
        fi
        run_watchable sleep "$CI_WATCH_RUN_APPEAR_POLL"
        bail_if_signaled $?
        waited=$((waited + CI_WATCH_RUN_APPEAR_POLL))
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
            printf 'Post-merge CI passed for the merge of %s (run %s)\n' "$BRANCH" "$id"
        else
            printf 'Post-merge CI FAILED for the merge of %s (run %s)\n' "$BRANCH" "$id"
        fi
    done <<<"$ids_text"

    # Every discovered run has been announced.  Exit 0 whatever the verdicts
    # were — reporting them IS the successful job.
    return 0
}

# The watcher body proper: everything that runs WHILE the lock is held.
# Reached only via `lockf`, as its `command` argument, so the kernel lock's
# lifetime is exactly this function's lifetime.
run_body() {
    # We are here, therefore we hold the lock.  Record the eviction target now,
    # before any slow call, so a newer watcher arriving a moment later has
    # something to aim at.
    write_pidfile
    log "acquired lock; mode=${MODE} branch=${BRANCH} repo=${OWNER_REPO}"
    if [[ "$MODE" == push ]]; then
        push_body
    else
        merge_body
    fi
}

# --- Lock acquire / eviction driver ----------------------------------------
# Runs the real body as `lockf`'s command.  Exit 75 (EX_TEMPFAIL) is the ONLY
# contention signal; any other code is the body's own completed outcome and is
# passed straight out.
acquire_and_run() {
    local attempt rc pgid
    local reentry_args=("$SELF" "$MODE" "$BRANCH" "$BODY_SENTINEL")
    [[ -n "$REPO_OVERRIDE" ]] && reentry_args+=(--repo "$REPO_OVERRIDE")
    for ((attempt = 1; attempt <= CI_WATCH_ACQUIRE_ATTEMPTS; attempt++)); do
        lockf -t 0 -k "$LOCKFILE" "$BASH" "${reentry_args[@]}"
        rc=$?
        if [[ "$rc" -ne 75 ]]; then
            exit "$rc"
        fi

        log "lock held (attempt ${attempt}/${CI_WATCH_ACQUIRE_ATTEMPTS}); evicting"
        pgid=$(read_pidfile_pgid)
        if [[ -z "$pgid" ]]; then
            # No recorded target.  A documented residual limitation, not a bug:
            # with nothing to signal, all we can do is wait out the holder.
            log "no usable PIDFILE; lock-probe-only wait up to ${CI_WATCH_NO_PID_WAIT}s"
            if probe_lock_free "$CI_WATCH_NO_PID_WAIT"; then
                continue
            fi
            printf 'Could not acquire lock for %s: it is held and no PID file names a process to signal\n' \
                "$BRANCH"
            exit 1
        fi

        kill -TERM -- -"$pgid" 2>/dev/null
        probe_lock_free "$CI_WATCH_EVICT_TERM_WAIT" && continue
        log "pgid ${pgid} did not release within ${CI_WATCH_EVICT_TERM_WAIT}s; escalating to SIGKILL"
        kill -KILL -- -"$pgid" 2>/dev/null
        probe_lock_free "$CI_WATCH_EVICT_KILL_WAIT"
    done
    printf 'Could not acquire lock for %s after %d attempts\n' "$BRANCH" "$CI_WATCH_ACQUIRE_ATTEMPTS"
    exit 1
}

# --- Entry point ------------------------------------------------------------
BODY_SENTINEL="__ci_watch_body"
# Absolute, so the re-entry through `lockf` cannot depend on the driver's cwd.
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

usage() {
    echo "Usage: ci_watch.sh push|merge '<branch>' [--repo owner/repo]" >&2
    exit 2
}

MODE="${1:-}"
case "$MODE" in
    push | merge) ;;
    *) usage ;;
esac

BRANCH="${2:-}"
# Strip leading/trailing whitespace: a pasted branch name with a stray space
# would otherwise hash to a key no other caller ever computes.
BRANCH="${BRANCH#"${BRANCH%%[![:space:]]*}"}"
BRANCH="${BRANCH%"${BRANCH##*[![:space:]]}"}"
[[ -n "$BRANCH" ]] || usage
# For merge mode this may also be a bare PR number, a PR URL, or any other
# selector `gh pr view`/`gh pr merge` itself accepts -- the caller (the
# PostToolUse hook) trusts an explicit target over guessing one from the
# current branch, and every gh call below already treats this value as an
# opaque selector string, never as something it parses itself.

# --- Remaining args: BODY_SENTINEL and/or --repo, order-independent. --------
# External callers pass MODE BRANCH [--repo owner/repo]; the internal lockf
# re-entry (acquire_and_run, below) additionally inserts BODY_SENTINEL,
# before or after --repo -- both are recognized regardless of position.
IS_BODY=0
REPO_OVERRIDE=""
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
        *)
            # Unrecognized extra argument: ignored defensively rather than
            # failing a re-entry this driver does not fully control the
            # shape of.
            shift
            ;;
    esac
done

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
        echo "Error: could not resolve owner/repo via gh; cannot key the ci watcher files." >&2
        exit 1
    fi
fi

KEY=$(_ci_watch_key "$OWNER_REPO" "$BRANCH") || exit 1
SLUG=$(_ci_slug "$BRANCH")

# Kind-scoped filenames: a push watcher and a merge watcher for the SAME branch
# use different lock files and therefore never contend with or evict each other.
LOCKFILE="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch2_lock_${MODE}_${SLUG}-${KEY}"
PIDFILE="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch2_pid_${MODE}_${SLUG}-${KEY}"
LOGFILE="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch2_${MODE}_${SLUG}-${KEY}.log"

# Stdout stays clean for the notification lines.  Everything else — including
# job control's own "[1]+ Done" chatter — goes to the per-key log.
exec 2>>"$LOGFILE"

if [[ "$IS_BODY" -eq 1 ]]; then
    run_body
    exit $?
fi

acquire_and_run
