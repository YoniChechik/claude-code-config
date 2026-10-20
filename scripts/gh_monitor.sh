#!/usr/bin/env bash
set -m
set -uo pipefail

exec </dev/null

: "${GH_MONITOR_CHECK_GRACE_MAX:=45}"
: "${GH_MONITOR_CHECK_GRACE_POLL:=5}"
: "${GH_MONITOR_MERGE_WAIT_MAX:=21600}"
: "${GH_MONITOR_MERGE_POLL:=20}"
: "${GH_MONITOR_RUN_APPEAR_MAX:=120}"
: "${GH_MONITOR_RUN_APPEAR_POLL:=10}"
: "${GH_MONITOR_MERGE_SETTLE:=300}"
: "${GH_MONITOR_DEPLOY_POLL:=30}"
: "${GH_MONITOR_RUN_POLL:=15}"
: "${GH_MONITOR_WATCH_MAX:=1320}"
: "${GH_MONITOR_POLL_FAIL_MAX:=10}"
: "${GH_MONITOR_IGNORE_EVENTS:=schedule,issue_comment,issues,pull_request_review,pull_request_review_comment,discussion,discussion_comment,label,milestone,project_card,watch,fork,gollum}"
: "${GH_MONITOR_WAIT_POLL:=10}"
: "${GH_MONITOR_WAIT_GRACE:=60}"
: "${GH_MONITOR_WAIT_MAX:=1620}"
: "${GH_MONITOR_RETRY_MAX:=3}"
: "${GH_MONITOR_RETRY_BACKOFF:=5}"
: "${GH_MONITOR_ACQUIRE_ATTEMPTS:=5}"
: "${GH_MONITOR_EVICT_TERM_WAIT:=10}"
: "${GH_MONITOR_EVICT_KILL_WAIT:=5}"
: "${GH_MONITOR_NO_PID_WAIT:=30}"
: "${GH_MONITOR_PROBE_POLL:=1}"

: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

FAILING_CONCLUSIONS='["failure","cancelled","timed_out","action_required","startup_failure"]'
PASSING_CONCLUSIONS='["success","neutral","skipped"]'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_notify.sh"
: "${GH_MONITOR_VERIFY_SCRIPT=${SCRIPT_DIR}/staging_verify.sh}"

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
            rc=0
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

bail_if_signaled() {
    case "$1" in
        143 | 130)
            log "signaled (rc=$1) — exiting without reporting"
            exit "$1"
            ;;
    esac
}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOGFILE" 2>/dev/null || true; }

pause() {
    run_watchable sleep "$1"
    bail_if_signaled $?
}

report() {
    printf '%s\n' "$*"
    [[ -n "${RESULT_PARTIAL:-}" ]] && printf '%s\n' "$*" >>"$RESULT_PARTIAL" 2>/dev/null
    return 0
}

finalize_result() {
    [[ -n "${RESULT_PARTIAL:-}" && -f "$RESULT_PARTIAL" ]] || return 0
    mv -f "$RESULT_PARTIAL" "$RESULT_FILE" 2>/dev/null || rm -f "$RESULT_PARTIAL"
}

GH_OUT=""
gh_call() {
    local attempt=1 out rc
    local terminal_rc="${GH_TERMINAL_RC:-}"
    while :; do
        out=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_call.XXXXXX") || {
            die_persistent "could not create a temp file"
        }
        run_watchable "$@" >"$out" 2>&1 </dev/null
        rc=$?
        GH_OUT=$(cat "$out" 2>/dev/null)
        log "\$ $* -> rc=$rc"
        cat "$out" >>"$LOGFILE" 2>/dev/null
        rm -f "$out"
        bail_if_signaled "$rc"
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
        pause "$GH_MONITOR_RETRY_BACKOFF"
    done
}

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
        pause "$GH_MONITOR_RETRY_BACKOFF"
    done
}

gh_call_best_effort() {
    local out rc
    out=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_call.XXXXXX") || {
        GH_OUT=""
        return 1
    }
    run_watchable "$@" >"$out" 2>"$out.err" </dev/null
    rc=$?
    GH_OUT=$(cat "$out" 2>/dev/null)
    log "\$ $* -> rc=$rc (best-effort)"
    cat "$out" "$out.err" >>"$LOGFILE" 2>/dev/null
    [[ "$rc" -eq 0 ]] || GH_OUT+=$'\n'$(cat "$out.err" 2>/dev/null)
    rm -f "$out" "$out.err"
    bail_if_signaled "$rc"
    return "$rc"
}

POLL_FAILS=0
poll_failed() {
    POLL_FAILS=$((POLL_FAILS + 1))
    log "poll failed (${POLL_FAILS}/${GH_MONITOR_POLL_FAIL_MAX} consecutive): $(short_reason "$GH_OUT")"
    if [[ "$POLL_FAILS" -ge "$GH_MONITOR_POLL_FAIL_MAX" ]]; then
        die_persistent "$(short_reason "$GH_OUT")"
    fi
}

is_retryable() {
    local rc="$1" text="$2"
    case "$rc" in 124 | 125 | 126 | 127) return 0 ;; esac
    shopt -s nocasematch
    local hit=1
    if [[ "$text" =~ (HTTP\ 401|HTTP\ 403|HTTP\ 429|HTTP\ 5[0-9][0-9]|rate\ limit|secondary\ rate|bad\ credentials|authentication\ failed|not\ logged\ into|gh\ auth\ login|could\ not\ resolve\ host|connection\ refused|connection\ reset|network\ is\ unreachable|no\ route\ to\ host|i/o\ timeout|timed\ out|timeout|tls\ handshake|eof|temporary\ failure|server\ error|service\ unavailable|try\ again) ]]; then
        hit=0
    fi
    shopt -u nocasematch
    return "$hit"
}

short_reason() {
    local line
    line=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -n 1)
    line=${line:0:120}
    printf '%s' "${line:-unknown error}"
}

die_persistent() {
    report "$(printf "CI watch for %s hit a persistent error: %s — stopping; run \`bash %s %s %s%s\` to retry" \
        "$TARGET" "$1" "$SELF" "$MODE" "$TARGET" "${RETRY_EXTRA:-}")"
    finalize_result
    exit 1
}

write_pidfile() {
    local pgid tmp
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

failed_jobs_for() {
    local run_id="$1"
    if gh_call_best_effort gh run view "$run_id" --repo "$OWNER_REPO" --json jobs \
        -q '[.jobs[] | select(.conclusion != null and .conclusion != "" and .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") | .name] | join(", ")'; then
        printf '%s' "$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r')"
    fi
}

last_line() {
    printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r'
}

is_gh_transport_error() {
    local line
    line=$(last_line "$1")
    [[ "$line" =~ ^((Post|Get|Put|Patch|Delete)\ \"https?://|HTTP\ [0-9]{3}) ]] || return 1
    is_retryable 1 "$line"
}

elapsed_since() { printf '%s' $(($(date +%s) - $1)); }

push_body() {
    local waited=0 rc
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
            report "No CI checks configured for $TARGET"
            return 0
        fi
        pause "$GH_MONITOR_CHECK_GRACE_POLL"
        waited=$((waited + GH_MONITOR_CHECK_GRACE_POLL))
    done

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
        pause "$GH_MONITOR_RETRY_BACKOFF"
    done
    if [[ "$rc" -eq 0 ]]; then
        report "CI passed for $TARGET"
        return 0
    fi
    case "$GH_OUT" in
        *"no checks reported"*)
            report "No CI checks configured for $TARGET"
            return 0
            ;;
    esac
    report "CI FAILED for $TARGET"
    return 0
}

SNAP_N=0
SUPER_LINES=""
cache_get() {
    local var="CACHE_${SNAP_N}_$1"
    [[ -n "${!var+x}" ]] || return 1
    CACHE_VAL=${!var}
}
cache_put() { printf -v "CACHE_${SNAP_N}_$1" '%s' "$2"; }

workflow_runs_for() {
    local wid="$1" branch="$2" key
    key="wf_${wid}_$(printf '%s' "$branch" | cksum | cut -d' ' -f1)"
    cache_get "$key" && return 0
    gh_call_best_effort gh api --method GET "repos/${OWNER_REPO}/actions/workflows/${wid}/runs" \
        -f "branch=${branch}" -f event=push -f per_page=100 \
        --jq '.workflow_runs[] | {id, status, conclusion, created_at, head_sha} | @json' \
        || return 1
    CACHE_VAL=$GH_OUT
    cache_put "$key" "$CACHE_VAL"
}

compare_status() {
    local base="$1" head="$2" key="cmp_${1}_${2}"
    cache_get "$key" && return 0
    gh_call_best_effort gh api "repos/${OWNER_REPO}/compare/${base}...${head}?per_page=1" \
        --jq '.status' || return 1
    CACHE_VAL=$(last_line "$GH_OUT")
    cache_put "$key" "$CACHE_VAL"
}

resolve_superseders() {
    local runs_out="$1" cancelled run id wid branch created sha cands cand cand_sha cand_id st best best_st
    SNAP_N=$((SNAP_N + 1))
    SUPER_LINES=""
    cancelled=$(printf '%s\n' "$runs_out" | jq -c 'select(type == "object" and .conclusion == "cancelled" and .event == "push") | {id, workflow_id, head_branch, created_at, head_sha}' 2>/dev/null) || cancelled=""
    [[ -n "$cancelled" ]] || return 0
    while IFS= read -r run; do
        [[ -n "$run" ]] || continue
        id=$(jq -r '.id' <<<"$run")
        wid=$(jq -r '.workflow_id' <<<"$run")
        branch=$(jq -r '.head_branch' <<<"$run")
        created=$(jq -r '.created_at' <<<"$run")
        sha=$(jq -r '.head_sha' <<<"$run")
        workflow_runs_for "$wid" "$branch" || return 1
        cands=$(printf '%s\n' "$CACHE_VAL" | jq -s -c --arg id "$id" --arg c "$created" \
            '[.[] | select((.id | tostring) != $id and .created_at > $c)] | sort_by(.created_at) | reverse | .[:5][]') || return 1
        [[ -n "$cands" ]] || continue
        best=""
        best_st=""
        while IFS= read -r cand; do
            [[ -n "$cand" ]] || continue
            cand_sha=$(jq -r '.head_sha' <<<"$cand")
            if [[ "$cand_sha" == "$sha" ]]; then
                st=identical
            else
                compare_status "$sha" "$cand_sha" || return 1
                st=$CACHE_VAL
            fi
            case "$st" in
                ahead | identical)
                    if [[ -z "$best" ]]; then
                        best=$cand
                        best_st=$st
                    fi
                    if [[ "$(jq -r '.conclusion' <<<"$cand")" != "cancelled" ]]; then
                        best=$cand
                        best_st=$st
                        break
                    fi
                    ;;
            esac
        done <<<"$cands"
        [[ -n "$best" ]] || continue
        cand_id=$(jq -r '.id' <<<"$best")
        SUPER_LINES+=$(jq -nc --argjson run_id "$id" --argjson c "$best" \
            '{kind: "super", run_id: $run_id, id: $c.id, status: $c.status, conclusion: $c.conclusion}')$'\n'
        log "run ${id} cancelled; superseded by run ${cand_id} (${best_st})"
    done <<<"$cancelled"
    return 0
}

SNAP_LINES=""
snapshot_sha() {
    local sha="$1" lines=""
    gh_call_best_effort gh api --paginate "repos/${OWNER_REPO}/actions/runs?head_sha=${sha}&per_page=100" \
        --jq '.workflow_runs[] | {kind: "run", id, name, status, conclusion, attempt: .run_attempt, event, workflow_id, head_branch, created_at, head_sha} | @json' \
        || return 1
    lines+=$GH_OUT$'\n'
    resolve_superseders "$GH_OUT" || return 1
    lines+=$SUPER_LINES
    gh_call_best_effort gh api --paginate "repos/${OWNER_REPO}/commits/${sha}/check-runs?filter=all&per_page=100" \
        --jq '.check_runs[] | {kind: "check", id, name, status, conclusion, app: (.app.slug // "")} | @json' \
        || return 1
    lines+=$GH_OUT$'\n'
    gh_call_best_effort gh api "repos/${OWNER_REPO}/commits/${sha}/status" \
        --jq '.statuses[] | {kind: "status", id, name: .context, state} | @json' \
        || return 1
    lines+=$GH_OUT$'\n'
    SNAP_LINES=$lines
    return 0
}

EVAL_TOTAL=0
EVAL_PENDING=0
EVAL_FAILED=0
EVAL_SIG=""
EVAL_DETAILS=""
evaluate_snapshot() {
    local out head
    out=$(printf '%s\n' "$SNAP_LINES" | jq -R -s -r \
        --argjson failing "$FAILING_CONCLUSIONS" \
        --arg ignore "$GH_MONITOR_IGNORE_EVENTS" '
        def concl: (.conclusion // "");
        def pad: (. + "                  ")[0:18];
        ($ignore | split(",")) as $ignored |
        [split("\n")[] | (fromjson? // empty) | select(type == "object" and has("kind"))] as $all
        | ($all | map(select(.kind == "run" and ((.event // "") as $e | $ignored | index($e) | not))) | group_by(.id) | map(max_by(.attempt // 1))) as $runs
        | ($all | map(select(.kind == "super") | {key: (.run_id | tostring), value: .}) | from_entries) as $sup
        | ($all | map(select(.kind == "check" and .app != "github-actions"))
            | group_by([.app, .name]) | map(max_by(.id))) as $checks
        | ($all | map(select(.kind == "status")) | group_by(.name) | map(max_by(.id))) as $statuses
        | [
            ($runs[] | concl as $c | $sup[(.id | tostring)] as $s
              | if $c == "cancelled" and $s != null then
                  (($s.conclusion // "") as $sc | {
                    sig: "run:\(.id)>\($s.id)",
                    done: ($sc != ""),
                    bad: ($sc != "" and ($failing | index($sc) != null)),
                    state: (if $sc == "" then "superseded-pending" elif ($failing | index($sc) != null) then $sc else "superseded" end),
                    label: "\(.name) (run \(.id), attempt \(.attempt // 1), \(.event // "?"), superseded by run \($s.id))"
                  })
                else {
                  sig: "run:\(.id)",
                  done: ($c != ""),
                  bad: ($failing | index($c) != null),
                  state: (if $c != "" then $c else (.status // "unknown") end),
                  label: "\(.name) (run \(.id), attempt \(.attempt // 1), \(.event // "?"))"
                } end),
            ($checks[] | {
                sig: "check:\(.app)/\(.name)",
                done: (concl != ""),
                bad: (concl as $c | $failing | index($c) != null),
                state: (if concl != "" then concl else (.status // "unknown") end),
                label: "\(.name) (check run, \(.app))"
            }),
            ($statuses[] | {
                sig: "status:\(.name)",
                done: (.state != "pending"),
                bad: (.state == "failure" or .state == "error"),
                state: .state,
                label: "\(.name) (commit status)"
            })
          ] as $items
        | "\($items | length) \($items | map(select(.done | not)) | length) \($items | map(select(.done and .bad)) | length) \($items | map(.sig) | sort | join(",") | @base64)",
          ($items | sort_by([(if .bad and .done then 0 elif .done then 2 else 1 end), .label])[]
            | "  \(.state | pad) \(.label)")
    ') || return 1
    head=$(printf '%s\n' "$out" | head -n 1)
    read -r EVAL_TOTAL EVAL_PENDING EVAL_FAILED EVAL_SIG <<<"$head"
    EVAL_SIG=${EVAL_SIG:-}
    EVAL_DETAILS=$(printf '%s\n' "$out" | tail -n +2)
    return 0
}

watch_merge_sha() {
    local sha="$1" label="$2" start prev_sig="" have_eval=0
    start=$(date +%s)
    while :; do
        if snapshot_sha "$sha" && evaluate_snapshot; then
            POLL_FAILS=0
            have_eval=1
            log "snapshot: total=${EVAL_TOTAL} pending=${EVAL_PENDING} failed=${EVAL_FAILED}"
            if [[ "$EVAL_TOTAL" -gt 0 && "$EVAL_PENDING" -eq 0 \
                && "$(elapsed_since "$start")" -ge "$GH_MONITOR_MERGE_SETTLE" \
                && "$EVAL_SIG" == "$prev_sig" ]]; then
                if [[ "$EVAL_FAILED" -gt 0 ]]; then
                    MERGE_CI=fail
                    report "Post-merge CI FAILED for ${label} on ${OWNER_REPO} (merge commit ${sha}): ${EVAL_FAILED} of ${EVAL_TOTAL} failed"
                else
                    MERGE_CI=pass
                    report "Post-merge CI PASSED for ${label} on ${OWNER_REPO} (merge commit ${sha}): all ${EVAL_TOTAL} green"
                fi
                report "$EVAL_DETAILS"
                return 0
            fi
            if [[ "$EVAL_TOTAL" -eq 0 && "$(elapsed_since "$start")" -ge "$GH_MONITOR_RUN_APPEAR_MAX" ]]; then
                MERGE_CI=none
                report "${label} merged on ${OWNER_REPO} (merge commit ${sha}); no post-merge CI run started within ${GH_MONITOR_RUN_APPEAR_MAX}s"
                return 0
            fi
            prev_sig=$EVAL_SIG
        else
            poll_failed
        fi
        if [[ "$(elapsed_since "$start")" -ge "$GH_MONITOR_WATCH_MAX" ]]; then
            MERGE_CI=timeout
            report "Post-merge verdict UNKNOWN (timeout): CI watch for ${label} on ${OWNER_REPO} (merge commit ${sha}) hit the ${GH_MONITOR_WATCH_MAX}s bound with ${EVAL_PENDING} still pending, ${EVAL_FAILED} failed so far"
            [[ "$have_eval" -eq 1 ]] && report "$EVAL_DETAILS"
            return 0
        fi
        pause "$GH_MONITOR_DEPLOY_POLL"
    done
}

merge_body() {
    local wait_start rc field state sha number title
    wait_start=$(date +%s)
    while :; do
        gh_call_nonempty gh pr view "$TARGET" --repo "$OWNER_REPO" \
            --json state,mergeCommit,number,title \
            -q '[.state, (.mergeCommit.oid // "-"), (.number | tostring), .title] | join("\t")'
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            die_persistent "$(short_reason "$GH_OUT")"
        fi
        field=$(printf '%s\n' "$GH_OUT" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r')
        IFS=$'\t' read -r state sha number title <<<"$field"
        state=${state//[[:space:]]/}
        sha=${sha//[[:space:]]/}
        case "$state" in
            MERGED)
                log "PR merged, commit=${sha}"
                break
                ;;
            CLOSED)
                report "PR #${number:-$TARGET} \"${title:-}\" on ${OWNER_REPO} closed without merging"
                return 0
                ;;
        esac
        if [[ "$(elapsed_since "$wait_start")" -ge "$GH_MONITOR_MERGE_WAIT_MAX" ]]; then
            report "$(printf "CI settled wait timed out; %s still not merged after 6h — stopping. Run \`bash %s merge %s --repo %s\` after you merge it." \
                "$TARGET" "$SELF" "$TARGET" "$OWNER_REPO")"
            return 0
        fi
        pause "$GH_MONITOR_MERGE_POLL"
    done
    if [[ -z "$sha" || "$sha" == "-" ]]; then
        die_persistent "PR is MERGED but GitHub reports no merge commit"
    fi
    MERGE_CI=timeout
    watch_merge_sha "$sha" "PR #${number} \"${title}\""
    staging_verify "$sha" "$number"
}

staging_verify() {
    [[ -n "$GH_MONITOR_VERIFY_SCRIPT" ]] || return 0
    local out
    log "staging verify: ci=${MERGE_CI}"
    local rc
    out=$(run_watchable bash "$GH_MONITOR_VERIFY_SCRIPT" "$OWNER_REPO" "$TARGET" "$2" "$1" "$MERGE_CI" 2>>"$LOGFILE")
    rc=$?
    bail_if_signaled "$rc"
    [[ -n "$out" ]] || out="Staging verify FAILED for ${OWNER_REPO} (merge commit $1): the verifier exited ${rc} without a verdict; see ${LOGFILE}"
    report "$out"
    return 0
}

run_body() {
    local run_id rc
    if [[ "$RUN_DISPATCH" -eq 1 ]]; then
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
                report "Dispatched $TARGET on $OWNER_REPO but no run appeared within ${GH_MONITOR_RUN_APPEAR_MAX}s"
                return 0
            fi
            pause "$GH_MONITOR_RUN_APPEAR_POLL"
            waited=$((waited + GH_MONITOR_RUN_APPEAR_POLL))
        done
        log "resolved dispatched run id=${run_id}"
    else
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
            pause "$GH_MONITOR_CHECK_GRACE_POLL"
            waited=$((waited + GH_MONITOR_CHECK_GRACE_POLL))
        done
        if [[ "$seen_run" -eq 0 ]]; then
            report "No CI run found for $run_id on $OWNER_REPO"
            return 0
        fi
    fi

    local start conclusion="" status="" line
    start=$(date +%s)
    while :; do
        if gh_call_best_effort gh run view "$run_id" --repo "$OWNER_REPO" --json status,conclusion \
            -q '(.status // "") + " " + (.conclusion // "")'; then
            POLL_FAILS=0
            line=$(printf '%s\n' "$GH_OUT" | grep -E '^[a-z_]+ ?[a-z_]*$' | tail -n 1)
            status=${line%% *}
            conclusion=${line#"$status"}
            conclusion=${conclusion//[[:space:]]/}
            [[ -n "$conclusion" ]] && break
        else
            poll_failed
        fi
        if [[ "$(elapsed_since "$start")" -ge "$GH_MONITOR_WATCH_MAX" ]]; then
            report "CI run $run_id on $OWNER_REPO still ${status:-unknown} after ${GH_MONITOR_WATCH_MAX}s — stopping the watch"
            return 0
        fi
        pause "$GH_MONITOR_RUN_POLL"
    done
    if printf '%s' "$PASSING_CONCLUSIONS" | jq -e --arg c "$conclusion" 'index($c) != null' >/dev/null 2>&1; then
        report "CI run $run_id passed for $OWNER_REPO ($conclusion)"
        return 0
    fi
    local jobs_line
    jobs_line=$(failed_jobs_for "$run_id")
    if [[ -n "$jobs_line" ]]; then
        report "CI run $run_id FAILED for $OWNER_REPO ($conclusion) — failed jobs: $jobs_line"
    else
        report "CI run $run_id FAILED for $OWNER_REPO ($conclusion)"
    fi
    return 0
}

wait_body() {
    local waited=0
    while :; do
        if [[ -s "$RESULT_FILE" ]]; then
            cat "$RESULT_FILE"
            return 0
        fi
        if [[ "$waited" -ge "$GH_MONITOR_WAIT_GRACE" ]] && lockf -t 0 -k "$LOCKFILE" true 2>/dev/null; then
            [[ -s "$RESULT_FILE" ]] && continue
            printf "No merge watcher is running for %s on %s and none recorded a result; start one with \`bash %s merge %s --repo %s --detach\`\n" \
                "$TARGET" "$OWNER_REPO" "$SELF" "$TARGET" "$OWNER_REPO"
            return 0
        fi
        if [[ "$waited" -ge "$GH_MONITOR_WAIT_MAX" ]]; then
            printf "Post-merge verdict UNKNOWN (timeout): no result recorded for %s on %s after %ss and the merge watcher is still running; see %s\n" \
                "$TARGET" "$OWNER_REPO" "$GH_MONITOR_WAIT_MAX" "$LOGFILE"
            return 0
        fi
        pause "$GH_MONITOR_WAIT_POLL"
        waited=$((waited + GH_MONITOR_WAIT_POLL))
    done
}

body_dispatch() {
    write_pidfile
    log "acquired lock; mode=${MODE} target=${TARGET} repo=${OWNER_REPO}"
    case "$MODE" in
        push) push_body ;;
        merge)
            RESULT_PARTIAL="${RESULT_FILE}.partial.$$"
            rm -f "$RESULT_FILE"
            merge_body
            finalize_result
            ;;
        run) run_body ;;
    esac
}

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

write_merge_meta() {
    local tmp
    tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR}/.gh_monitor_tmp_meta.XXXXXX") || return 1
    {
        printf 'session=%s\n' "${CLAUDE_CODE_SESSION_ID:-}"
        printf 'target=%s\n' "$TARGET"
        printf 'repo=%s\n' "$OWNER_REPO"
        printf 'started=%s\n' "$(date +%s)"
        printf 'result=%s\n' "$RESULT_FILE"
        printf 'wait_cmd=bash %s wait %s --repo %s\n' "$SELF" "$TARGET" "$OWNER_REPO"
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$META_FILE.announced"
}

detach_merge() {
    rm -f "$RESULT_FILE"
    write_merge_meta || {
        echo "Error: could not write $META_FILE" >&2
        exit 1
    }
    GH_MONITOR_META_WRITTEN=1 nohup perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exec @ARGV' \
        "$BASH" "$SELF" merge "$TARGET" --repo "$OWNER_REPO" \
        >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
    printf '%s\n' "$META_FILE"
    exit 0
}

BODY_SENTINEL="__gh_monitor_body"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

usage() {
    cat >&2 <<'USAGE'
Usage:
  gh_monitor.sh push  '<branch>'                                    [--repo owner/repo]
  gh_monitor.sh merge '<branch|PR>'                                 [--repo owner/repo] [--detach]
  gh_monitor.sh wait  '<branch|PR>'                                 [--repo owner/repo]
  gh_monitor.sh run   '<run-id>'                                    [--repo owner/repo]
  gh_monitor.sh run   '<workflow-file>' --dispatch [--ref <ref>] [-f key=value ...] [--repo owner/repo]
USAGE
    exit 2
}

MODE="${1:-}"
case "$MODE" in
    push | merge | wait | run) ;;
    *) usage ;;
esac

TARGET="${2:-}"
TARGET="${TARGET#"${TARGET%%[![:space:]]*}"}"
TARGET="${TARGET%"${TARGET##*[![:space:]]}"}"
[[ -n "$TARGET" ]] || usage

IS_BODY=0
REPO_OVERRIDE=""
RUN_DISPATCH=0
DETACH=0
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
        --detach)
            [[ "$MODE" == merge ]] || usage
            DETACH=1
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
            shift
            ;;
    esac
done

if [[ "$MODE" == run && "$RUN_DISPATCH" -eq 0 ]]; then
    [[ -n "$RUN_REF" ]] && usage
    [[ "${#RUN_FIELDS[@]}" -eq 0 ]] || usage
fi

if [[ "$MODE" == run && "$RUN_DISPATCH" -eq 1 ]]; then
    RETRY_EXTRA=" --dispatch"
    [[ -n "$RUN_REF" ]] && RETRY_EXTRA+=" --ref $RUN_REF"
    for field in "${RUN_FIELDS[@]:-}"; do
        [[ -n "$field" ]] && RETRY_EXTRA+=" -f $field"
    done
fi

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
[[ "$MODE" == merge || "$MODE" == wait ]] && RETRY_EXTRA=" --repo $OWNER_REPO"

KEY=$(_gh_monitor_key "$OWNER_REPO" "$TARGET") || exit 1
SLUG=$(_gh_monitor_slug "$TARGET")

FILE_MODE="$MODE"
[[ "$MODE" == wait ]] && FILE_MODE=merge
LOCKFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_lock_${FILE_MODE}_${SLUG}-${KEY}"
PIDFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_pid_${FILE_MODE}_${SLUG}-${KEY}"
LOGFILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_${MODE}_${SLUG}-${KEY}.log"
RESULT_FILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_result_merge_${SLUG}-${KEY}"
META_FILE="${CLAUDE_NOTIFY_TMP_DIR}/gh_monitor_watch_merge_${SLUG}-${KEY}.meta"
RESULT_PARTIAL=""

exec 2>>"$LOGFILE"

if [[ "$IS_BODY" -eq 1 ]]; then
    body_dispatch
    exit $?
fi

case "$MODE" in
    wait)
        wait_body
        exit $?
        ;;
    merge)
        [[ "$DETACH" -eq 1 ]] && detach_merge
        if [[ "${GH_MONITOR_META_WRITTEN:-0}" != 1 ]]; then
            write_merge_meta || log "warning: could not write $META_FILE"
        fi
        unset GH_MONITOR_META_WRITTEN
        ;;
esac

acquire_and_run
