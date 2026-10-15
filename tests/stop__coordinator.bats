#!/usr/bin/env bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
HOOK="$SCRIPTS/stop__coordinator.sh"
CONTEXT_HOOK="$SCRIPTS/prompt_context__done_gate.sh"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures/done_gate"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"
SHA=abcdef1234567890abcdef1234567890abcdef12

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR/notify"
    mkdir -p "$CLAUDE_NOTIFY_TMP_DIR"
    SID=s1
    PID=p1
    TASKS='[]'
    CRONS='[]'
    ACTIVE=false
    SDIR="$CLAUDE_STATE_DIR/sessions/$SID"
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

stop() {
    jq -nc --arg m "$1" --arg s "$SID" --arg p "$PID" --argjson t "$TASKS" --argjson c "$CRONS" --argjson a "$ACTIVE" \
        '{hook_event_name: "Stop", session_id: $s, prompt_id: $p, stop_hook_active: $a, last_assistant_message: $m, background_tasks: $t, session_crons: $c}' |
        bash "$HOOK"
}

decision() { if [ -z "$1" ]; then echo allow; else printf "%s" "$1" | jq -r ".decision // \"allow\""; fi; }
hook_log_text() { cat "$CLAUDE_HOOK_LOG_DIR/hooks.log" 2>/dev/null; }
reason() { printf '%s' "$1" | jq -r '.reason // ""'; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""'; }

init_state() { mkdir -p "$SDIR" && chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/sessions" "$SDIR"; }

ledger() {
    init_state
    local rec
    for rec in "$@"; do printf '%s\n' "$rec" >>"$SDIR/ledger.jsonl"; done
}

now() { date +%s; }

merge_rec() { printf '{"kind":"merge","repo":"o/r","target":"%s","pr":"%s","wait_cmd":"bash /x/gh_monitor.sh wait %s --repo o/r","prompt_id":"%s","ts":%s}' "$1" "${PR_NUM:-$1}" "$1" "${2:-$PID}" "${3:-$(($(now) - 100))}"; }

verify_rec() {
    printf '{"kind":"verify","repo":"o/r","target":"%s","pr":"%s","merge_sha":"%s","result":"%s","reason":"r","targets":[{"name":"staging","observed_sha":"%s","probes":[{"url":"https://x","exit":%s,"matched":true}]}],"ts":%s}' \
        "$1" "${PR_NUM:-$1}" "$SHA" "${2:-pass}" "${3:-${SHA:0:12}}" "${4:-0}" "$(($(now) - 50))"
}

wait_task() { printf '[{"id":"%s","type":"shell","status":"%s","description":"%s","command":"%s"}]' "$1" "${2:-running}" "$3" "$4"; }

fixture_blocks() {
    local rule
    rule=$(basename "$1")
    rule=${rule%%__*}
    run stop "$(cat "$1")"
    assert_eq 0 "$status"
    assert_eq block "$(decision "$output")"
    assert_contains "$rule:" "$(reason "$output")"
    assert_contains "block 1/3 rules=$rule session=s1" "$(hook_log_text)"
}

fixture_passes() {
    run stop "$(cat "$1")"
    assert_eq 0 "$status"
    assert_eq allow "$(decision "$output")"
    assert_not_contains "Stop gate error" "$(sysmsg "$output")"
    assert_contains "pass session=s1" "$(hook_log_text)"
}

for fixture in "$FIXTURES"/block/*.txt; do
    bats_test_function --description "fixture blocks: ${fixture##*/}" -- fixture_blocks "$fixture"
done
for fixture in "$FIXTURES"/pass/*.txt; do
    bats_test_function --description "fixture passes: ${fixture##*/}" -- fixture_passes "$fixture"
done

@test "the fixture sets are complete" {
    assert_eq 26 "$(find "$FIXTURES/block" -name '*.txt' | wc -l | tr -d ' ')"
    assert_eq 13 "$(find "$FIXTURES/pass" -name '*.txt' | wc -l | tr -d ' ')"
}

@test "the gate enforces with no configuration and logs the decision per rule" {
    run stop "$(cat "$FIXTURES/block/G1__merge_handoff.txt")"
    assert_eq 0 "$status"
    assert_eq block "$(decision "$output")"
    assert_contains "block 1/3 rules=G1 session=s1" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "a subagent stop is never gated" {
    run bash -c "jq -nc '{hook_event_name:\"Stop\",session_id:\"s1\",agent_id:\"a1\",last_assistant_message:\"Should I merge?\"}' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "bad input never fails: exit 0, no output, and a logged skip" {
    local payload
    for payload in 'not json' '' '{}' '{"hook_event_name":"Stop"}' '[]'; do
        rm -f "$CLAUDE_HOOK_LOG_DIR/hooks.log"
        run bash -c "printf '%s' '$payload' | bash '$HOOK'"
        assert_eq 0 "$status"
        assert_eq "" "$output"
    done
    run bash -c "printf 'not json' | bash '$HOOK'"
    assert_contains "skip: bad hook input JSON" "$(hook_log_text)"
}

@test "an unsafe session id is untrusted and nothing is written outside the state root" {
    SID='../../escape'
    run stop "STATUS: ANSWER"
    assert_eq 0 "$status"
    assert_contains "state directory is untrusted (invalid session id)" "$(reason "$output")"
    [ ! -e "$BATS_TEST_TMPDIR/escape" ]
    [ ! -e "$CLAUDE_STATE_DIR/escape" ]
}

@test "a null last message and non-array task lists are a missing STATUS, not a crash" {
    run bash -c "jq -nc '{hook_event_name:\"Stop\",session_id:\"s1\",last_assistant_message:null,background_tasks:\"x\",session_crons:7}' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_contains "G1: the last line is not a STATUS line" "$(reason "$output")"
    assert_not_contains "error" "$(hook_log_text)"
}

@test "a missing state root parent is untrusted state, not a crash" {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/no/such/dir"
    run stop "STATUS: ANSWER"
    assert_eq 0 "$status"
    assert_contains "state directory is untrusted" "$(reason "$output")"
}

@test "a huge final message and a ledger over 1 MB are evaluated without argv limits" {
    init_state
    local pad i
    pad=$(head -c 4000 /dev/zero | tr '\0' x)
    for i in $(seq 1 300); do printf '{"kind":"check","item":0,"pred_sha":"z","exit":0,"pad":"%s","ts":1}\n' "$pad"; done >"$SDIR/ledger.jsonl"
    printf '%s\n' "$(merge_rec 4016 p0)" "$(verify_rec 4016)" >>"$SDIR/ledger.jsonl"
    (($(wc -c <"$SDIR/ledger.jsonl") > 1048576))
    { head -c 2000000 /dev/zero | tr '\0' y; printf '\n\nSTATUS: ANSWER'; } >"$BATS_TEST_TMPDIR/msg"
    jq -nc --rawfile m "$BATS_TEST_TMPDIR/msg" '{hook_event_name: "Stop", session_id: "s1", prompt_id: "p1", last_assistant_message: $m}' >"$BATS_TEST_TMPDIR/payload"
    run bash -c "bash '$HOOK' <'$BATS_TEST_TMPDIR/payload'"
    assert_eq 0 "$status"
    assert_eq allow "$(decision "$output")"
    assert_contains "pass session=s1" "$(hook_log_text)"
    assert_not_contains "evaluation failed" "$(hook_log_text)"
}

@test "an unparseable ledger line is logged as an error" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)" '{"kind":"merge","repo":"o/r",'
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
    assert_contains "error: 1 unparseable ledger lines session=s1" "$(hook_log_text)"
}

@test "G1: a STATUS line wrapped in markdown is still read" {
    run stop $'Answer.\n\n`STATUS: ANSWER`'
    assert_eq allow "$(decision "$output")"
}

@test "G1: an unknown status keyword is refused" {
    run stop "STATUS: DONE everything"
    assert_contains "is not a valid status" "$(reason "$output")"
}

@test "G1: ANSWER is refused in a prompt that merged" {
    ledger "$(merge_rec 4016)" "$(verify_rec 4016)"
    run stop "STATUS: ANSWER"
    assert_contains "G1: \`STATUS: ANSWER\` is only for a pure answer" "$(reason "$output")"
}

@test "G1: ANSWER is fine in a later prompt after the merge was verified" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)"
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a merge without a staging result blocks with the exact waiter command" {
    ledger "$(merge_rec 4016)"
    run stop "STATUS: COMPLETE merged"
    assert_eq block "$(decision "$output")"
    assert_contains "G2: o/r#4016 is merged and has no staging verify result yet. Run \`bash /x/gh_monitor.sh wait 4016 --repo o/r\` with \`run_in_background: true\`" "$(reason "$output")"
}

@test "G2: a merge recorded by branch clears on the verify record of its PR number" {
    PR_NUM=123 ledger "$(PR_NUM=123 merge_rec feat/x p0)" "$(PR_NUM=123 verify_rec feat/x)" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE staging serves the merge"
    assert_eq allow "$(decision "$output")"
}

@test "G4: merged:<repo>#<pr> clears for a branch merge even when the verify record targets the branch" {
    ledger "$(PR_NUM=123 merge_rec feat/x p0)" '{"kind":"verify","repo":"o/r","target":"feat/x","pr":"123","merge_sha":"'"$SHA"'","result":"pass","targets":[{"name":"s","observed_sha":"'"${SHA:0:12}"'","probes":[]}],"ts":'"$(now)"'}' \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE done"
    assert_eq allow "$(decision "$output")"
}

pass_targets_rec() {
    printf '{"kind":"verify","repo":"o/r","target":"123","pr":"123","merge_sha":"%s","result":"%s","reason":"r","targets":%s,"ts":%s}' \
        "$SHA" "$1" "$2" "$(($(now) - 50))"
}

skipped_target='{"name":"other","skipped":true,"reason":"merge touches none of its paths"}'

@test "G2: a pass with one verified target and one skipped target clears" {
    local ok='{"name":"s","observed_sha":"'"${SHA:0:12}"'","contains_merge":true,"probes":[{"url":"https://x","exit":0,"matched":true}]}'
    ledger "$(PR_NUM=123 merge_rec 123)" "$(pass_targets_rec pass "[$ok,$skipped_target]")" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE merged"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a pass whose targets are all skipped does not clear" {
    ledger "$(PR_NUM=123 merge_rec 123)" "$(pass_targets_rec pass "[$skipped_target]")" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE merged"
    assert_eq block "$(decision "$output")"
}

@test "G2: an n/a record with all targets skipped clears" {
    ledger "$(PR_NUM=123 merge_rec 123)" "$(pass_targets_rec n/a "[$skipped_target]")" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE merged"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a pass with a verified target lacking observed_sha does not clear even beside a skipped one" {
    local bad='{"name":"s","observed_sha":"","contains_merge":true,"probes":[]}'
    ledger "$(PR_NUM=123 merge_rec 123)" "$(pass_targets_rec pass "[$bad,$skipped_target]")" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE merged"
    assert_eq block "$(decision "$output")"
}

@test "G2: a pass with a failing probe beside a skipped target does not clear" {
    local bad='{"name":"s","observed_sha":"'"${SHA:0:12}"'","contains_merge":true,"probes":[{"url":"https://x","exit":22,"matched":false}]}'
    ledger "$(PR_NUM=123 merge_rec 123)" "$(pass_targets_rec pass "[$bad,$skipped_target]")" \
        '{"kind":"predicate","items":["merged:o/r#123"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE merged"
    assert_eq block "$(decision "$output")"
}

@test "G2: a FAILURE whose what-part does not name the PR never acks it, even if the number appears in the evidence" {
    ledger "$(merge_rec 12 p0)" "$(verify_rec 12 fail)"
    run stop "STATUS: FAILURE build: exit 12 from npm"
    assert_eq block "$(decision "$output")"
    assert_contains "G2: staging verify for o/r#12 returned fail" "$(reason "$output")"
    assert_eq 0 "$(jq -s 'map(select(.kind == "ack")) | length' "$SDIR/ledger.jsonl")"
}

@test "G2: a FAILURE naming the PR by URL, by #n or by repo#n acks it" {
    local what
    for what in "https://github.com/o/r/pull/12" "#12" "o/r#12" "PR 12"; do
        SID="u${#what}"
        SDIR="$CLAUDE_STATE_DIR/sessions/$SID"
        ledger "$(merge_rec 12 p0)" "$(verify_rec 12 fail)"
        run stop "STATUS: FAILURE $what: staging serves 0000000 after 1800s"
        assert_eq allow "$(decision "$output")" || { echo "not acked: $what" >&2; return 1; }
        assert_eq 1 "$(jq -s 'map(select(.kind == "ack")) | length' "$SDIR/ledger.jsonl")"
    done
}

@test "G2: an ack for one PR does not clear another" {
    ledger "$(merge_rec 12 p0)" "$(verify_rec 12 fail)" "$(merge_rec 13 p0)" "$(verify_rec 13 fail)"
    run stop "STATUS: FAILURE #12: staging down"
    assert_eq block "$(decision "$output")"
    assert_contains "o/r#13" "$(reason "$output")"
    assert_not_contains "o/r#12 " "$(reason "$output")"
}

@test "G2: a merge recorded without a repo still gets a clean message and no dangling --repo" {
    ledger '{"kind":"merge","repo":"","target":"feat-x","pr":"","wait_cmd":"","ts":'"$(($(now) - 100))"'}'
    run stop "STATUS: COMPLETE merged"
    assert_contains "G2: PR feat-x is merged" "$(reason "$output")"
    assert_contains "gh_monitor.sh wait feat-x\` with" "$(reason "$output")"
    assert_not_contains "--repo \`" "$(reason "$output")"
}

@test "G2: WAITING on the live gh_monitor waiter for that PR passes" {
    ledger "$(merge_rec 4016)"
    TASKS=$(wait_task b1 running "deploy 4016" "bash /x/gh_monitor.sh wait 4016 --repo o/r")
    run stop "STATUS: WAITING b1 deploy 4016"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a passing verify record whose observed SHA matches the merge clears the merge" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)"
    run stop "STATUS: FAILURE other: unrelated evidence"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a pass record with a different observed SHA does not count" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016 pass 9999999999)"
    run stop "STATUS: FAILURE other: unrelated evidence"
    assert_contains "does not prove the merge" "$(reason "$output")"
}

@test "G2: a pass record with a failing probe does not count" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016 pass "${SHA:0:12}" 1)"
    run stop "STATUS: FAILURE other: unrelated evidence"
    assert_eq block "$(decision "$output")"
}

@test "G2: a missing verify config asks for the no-verify-config FAILURE, which then acks the merge" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016 no-config)"
    run stop "STATUS: ANSWER"
    assert_contains "o/r#4016 cannot be verified on staging: r. Create the config with \`/create-verification-skill\`" "$(reason "$output")"
    assert_contains "STATUS: FAILURE no-verify-config: o/r#4016" "$(reason "$output")"
    PID=p2
    run stop "STATUS: FAILURE no-verify-config: o/r#4016"
    assert_eq allow "$(decision "$output")"
    assert_eq ack "$(jq -rs 'map(select(.kind == "ack"))[0].kind' "$SDIR/ledger.jsonl")"
    PID=p3
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
}

@test "G2: a FAILURE that names the PR acks it" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016 fail)"
    run stop "STATUS: FAILURE 4016: staging serves 0000000 after 1800s"
    assert_eq allow "$(decision "$output")"
    PID=p9
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
}

@test "G3: WAITING on a running tagged watcher passes" {
    TASKS=$(wait_task b7 running "[wait:store-1.73.0] poll Play review" "while :; do x; done")
    run stop "STATUS: WAITING b7 store-1.73.0"
    assert_eq allow "$(decision "$output")"
}

@test "G3: a tail -f with no tag is not a watcher" {
    TASKS=$(wait_task b7 running "tail logs" "tail -f /dev/null")
    run stop "STATUS: WAITING b7 deploy"
    assert_contains "G3: task \`b7\` is not a watcher" "$(reason "$output")"
}

@test "G3: the STATUS line must name the watcher tag" {
    TASKS=$(wait_task b7 running "[wait:store-1.73.0] poll" "x")
    run stop "STATUS: WAITING b7 something else"
    assert_contains "must name the watcher tag \`store-1.73.0\`" "$(reason "$output")"
}

@test "G3: a finished task does not satisfy WAITING" {
    TASKS=$(wait_task b7 completed "[wait:x] poll" "x")
    run stop "STATUS: WAITING b7 x"
    assert_contains "is \`completed\`, not running" "$(reason "$output")"
}

seen_at() { init_state; printf '{"tasks":{"%s":%s},"pred_ack":""}' "$1" "$2" >"$SDIR/gate.json"; }

@test "G3: a watcher older than its TTL fails" {
    seen_at b7 "$(($(now) - 600))"
    TASKS=$(wait_task b7 running "[wait:x] ttl=5 poll" "x")
    run stop "STATUS: WAITING b7 x"
    assert_contains "longer than its TTL of 5 min" "$(reason "$output")"
}

@test "G3: the TTL boundary: just inside passes, just outside fails" {
    TASKS=$(wait_task b7 running "[wait:x] ttl=5 poll" "x")
    seen_at b7 "$(($(now) - 290))"
    run stop "STATUS: WAITING b7 x"
    assert_eq allow "$(decision "$output")"
    seen_at b7 "$(($(now) - 310))"
    PID=p2
    run stop "STATUS: WAITING b7 x"
    assert_contains "longer than its TTL of 5 min" "$(reason "$output")"
}

@test "G3: without ttl= the TTL is 120 minutes" {
    TASKS=$(wait_task b7 running "[wait:x] poll" "x")
    seen_at b7 "$(($(now) - 119 * 60))"
    run stop "STATUS: WAITING b7 x"
    assert_eq allow "$(decision "$output")"
    seen_at b7 "$(($(now) - 121 * 60))"
    PID=p2
    run stop "STATUS: WAITING b7 x"
    assert_contains "longer than its TTL of 120 min" "$(reason "$output")"
}

@test "G3: WAITING on an unknown task id is refused by name" {
    run stop "STATUS: WAITING zz9 deploy"
    assert_contains "no running background task or cron has id \`zz9\`" "$(reason "$output")"
}

@test "G3: a task gone from the task list but still in gate.json is not a wait" {
    seen_at b7 "$(now)"
    run stop "STATUS: WAITING b7 x"
    assert_contains "no running background task or cron has id \`b7\`" "$(reason "$output")"
}

@test "G3: a finished task drops out of gate.json, so a relaunch with the same id starts a fresh TTL" {
    seen_at b7 "$(($(now) - 600))"
    TASKS=$(wait_task b7 completed "[wait:x] ttl=5 poll" "x")
    stop "STATUS: ANSWER" >/dev/null
    assert_eq null "$(jq -r '.tasks.b7' "$SDIR/gate.json")"
    TASKS=$(wait_task b7 running "[wait:x] ttl=5 poll" "x")
    PID=p2
    run stop "STATUS: WAITING b7 x"
    assert_eq allow "$(decision "$output")"
}

@test "G3: the first sighting of a task is recorded for the TTL" {
    TASKS=$(wait_task b7 running "[wait:x] poll" "x")
    stop "STATUS: WAITING b7 x" >/dev/null
    [[ $(jq -r '.tasks.b7' "$SDIR/gate.json") =~ ^[0-9]+$ ]]
}

@test "G3: a session cron and a running subagent are valid waits" {
    CRONS='[{"id":"c1","schedule":"*/5 * * * *","recurring":true,"prompt":"check"}]'
    run stop "STATUS: WAITING c1 nightly build"
    assert_eq allow "$(decision "$output")"
    TASKS='[{"id":"a9","type":"subagent","status":"running","description":"verify staging","agent_type":"general-purpose"}]'
    run stop "STATUS: WAITING a9 staging verification"
    assert_eq allow "$(decision "$output")"
}

@test "G4: COMPLETE after a verified merge needs a recorded predicate" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)"
    run stop "STATUS: COMPLETE verified"
    assert_contains "no exit predicate is recorded" "$(reason "$output")"
}

@test "G4: a prose-only predicate is refused for merging work" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)" '{"kind":"predicate","items":["feature works"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE verified"
    assert_contains "has no machine-checkable item" "$(reason "$output")"
}

@test "G4: merged: and staging: items are met by the verify record, and prose items are shown back" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)" '{"kind":"predicate","items":["merged:o/r#4016","staging:o/r","banner looks right"],"sha256":"a","ts":1}'
    run stop "STATUS: COMPLETE staging serves the merge sha"
    assert_eq allow "$(decision "$output")"
    assert_contains "Claimed without machine proof: banner looks right" "$(sysmsg "$output")"
}

@test "G4: a cmd: item needs a passing check taken after the last merge" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)" '{"kind":"predicate","items":["cmd:true"],"sha256":"h1","ts":1}' \
        '{"kind":"check","item":0,"pred_sha":"h1","exit":0,"ts":2}'
    run stop "STATUS: COMPLETE checked"
    assert_contains "done_gate.sh check 0" "$(reason "$output")"
    printf '{"kind":"check","item":0,"pred_sha":"h1","exit":0,"ts":%s}\n' "$(now)" >>"$SDIR/ledger.jsonl"
    PID=p5
    run stop "STATUS: COMPLETE checked"
    assert_eq allow "$(decision "$output")"
}

@test "G4: a predicate written by rename_session with an ISO timestamp is understood" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016)" '{"ts":"2026-10-14T09:00:00Z","kind":"predicate","items":["merged:o/r#4016"],"sha256":"z"}'
    run stop "STATUS: COMPLETE done"
    assert_eq allow "$(decision "$output")"
}

@test "G4: a predicate changed during this prompt blocks once and shows old and new" {
    init_state
    jq -nc --argjson ts "$(($(now) - 10))" '{id: "p1", ts: $ts}' >"$SDIR/prompt.json"
    ledger "$(merge_rec 4016 p0 1)" "$(verify_rec 4016)" \
        '{"kind":"predicate","items":["merged:o/r#4016","cmd:old"],"sha256":"old","ts":2}' \
        "$(printf '{"kind":"predicate","items":["merged:o/r#4016"],"sha256":"new","ts":%s}' "$(now)")"
    run stop "STATUS: COMPLETE done"
    assert_contains "the exit predicate changed during this prompt" "$(reason "$output")"
    assert_contains "Old: merged:o/r#4016 | cmd:old. New: merged:o/r#4016." "$(sysmsg "$output")"
    run stop "STATUS: COMPLETE done, predicate narrowed because cmd:old is obsolete"
    assert_eq allow "$(decision "$output")"
}

@test "G4: COMPLETE with no merge or push in the session needs no predicate" {
    run stop "STATUS: COMPLETE answered with evidence in the report above"
    assert_eq allow "$(decision "$output")"
}

@test "cap: blocks 1 and 2 name the fix, block 3 demands FAILURE, then the stop passes and is carried over" {
    run stop "Should I merge PR #135?"
    assert_contains "Stop gate (block 1 of 3)" "$(reason "$output")"
    run stop "Should I merge PR #135?"
    assert_contains "Stop gate (block 2 of 3)" "$(reason "$output")"
    run stop "Should I merge PR #135?"
    assert_contains "end now with \`STATUS: FAILURE <rule>: <what you tried and observed>\`" "$(reason "$output")"
    run stop "Should I merge PR #135?"
    assert_eq allow "$(decision "$output")"
    assert_contains "Stop gate: unresolved G1, recorded and carried over" "$(sysmsg "$output")"
    assert_eq G1 "$(jq -r '.rules[0].rule' "$SDIR/unresolved.json")"
    assert_contains "CAP_HIT rules=G1" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "cap: stop_hook_active does not bypass the counter" {
    ACTIVE=true
    run stop "Should I?"
    assert_contains "Stop gate (block 1 of 3)" "$(reason "$output")"
    run stop "Should I?"
    assert_contains "Stop gate (block 2 of 3)" "$(reason "$output")"
}

@test "cap: a garbage counter file counts as zero" {
    init_state
    printf 'not json' >"$SDIR/counter.json"
    run stop "Should I?"
    assert_contains "Stop gate (block 1 of 3)" "$(reason "$output")"
}

@test "cap: a counter that cannot be saved fails open instead of blocking forever" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/mktemp"
    chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
    local i
    for i in 1 2 3 4 5; do
        run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$(declare -f stop); SID=$SID PID=$PID TASKS='[]' CRONS='[]' ACTIVE=false HOOK='$HOOK' stop 'Should I?'"
        assert_eq allow "$(decision "$output")"
    done
    assert_contains "block counter cannot be saved, so the stop was allowed" "$(sysmsg "$output")"
    assert_contains "FAIL_OPEN: cannot save the block counter" "$(hook_log_text)"
}

@test "cap: counters and carry-over are isolated per session" {
    local i
    for i in 1 2 3 4; do stop "Should I?" >/dev/null; done
    [ -s "$SDIR/unresolved.json" ]
    SID=s2
    SDIR="$CLAUDE_STATE_DIR/sessions/s2"
    ledger "$(merge_rec 77 p0)"
    run stop "Should I?"
    assert_contains "Stop gate (block 1 of 3)" "$(reason "$output")"
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt_id:\"p9\",prompt:\"go\"}' | bash '$CONTEXT_HOOK'"
    assert_not_contains "o/r#77" "$output"
    assert_contains "G1: the last line is not a STATUS line" "$output"
}

@test "cap: the counter is per prompt" {
    stop "Should I?" >/dev/null
    stop "Should I?" >/dev/null
    stop "Should I?" >/dev/null
    PID=p2
    run stop "Should I?"
    assert_contains "Stop gate (block 1 of 3)" "$(reason "$output")"
}

@test "carry-over: the next prompt gets the unresolved rules and pending merges until a clean stop clears them" {
    ledger "$(merge_rec 4016 p0)"
    for _ in 1 2 3 4; do stop "Should I merge?" >/dev/null; done
    [ -s "$SDIR/unresolved.json" ]
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt_id:\"p2\",prompt:\"go\"}' | bash '$CONTEXT_HOOK'"
    c=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_contains "Unresolved from the last turn" "$c"
    assert_contains "o/r#4016 (merged" "$c"
    assert_contains "G1: the last line is not a STATUS line" "$c"
    assert_eq p2 "$(jq -r .id "$SDIR/prompt.json")"
    PID=p2
    printf '%s\n' "$(verify_rec 4016)" >>"$SDIR/ledger.jsonl"
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
    [ ! -e "$SDIR/unresolved.json" ]
}

@test "carry-over: an Esc-interrupted merge (no Stop ran) is still re-raised on the next prompt" {
    ledger "$(merge_rec 4016 p0)"
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt:\"hi\"}' | bash '$CONTEXT_HOOK'"
    assert_contains "o/r#4016 (merged" "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
}

@test "session start injects the session-name line and the carry-over" {
    ledger "$(merge_rec 4016 p0)"
    run bash -c "jq -nc '{hook_event_name:\"SessionStart\",session_id:\"s1\",source:\"resume\"}' | bash '$CONTEXT_HOOK'"
    c=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_eq SessionStart "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    assert_contains "Run /session-name <label> now, and add --done '<exit predicate item>'" "$c"
    assert_contains "o/r#4016 (merged" "$c"
}

@test "a prompt without a prompt_id gets a unique synthetic id, so repeated identical prompts do not share a counter" {
    jq -nc '{hook_event_name:"UserPromptSubmit",session_id:"s1",prompt:"go"}' | bash "$CONTEXT_HOOK" >/dev/null
    local first
    first=$(jq -r .id "$SDIR/prompt.json")
    assert_eq true "$(jq -r .synthetic "$SDIR/prompt.json")"
    [[ $first =~ ^t[0-9]+-[0-9a-f]{16}$ ]]
    jq -nc '{hook_event_name:"UserPromptSubmit",session_id:"s1",prompt:"go"}' | bash "$CONTEXT_HOOK" >/dev/null
    [ "$first" != "$(jq -r .id "$SDIR/prompt.json")" ]
}

@test "the session-name re-check is nudged on a prompt 30 minutes after the last nudge" {
    init_state
    printf '%s' "$(($(now) - 1801))" >"$SDIR/name_nudge"
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt_id:\"p2\",prompt:\"go\"}' | bash '$CONTEXT_HOOK'"
    assert_contains "The session label may be stale. Run /session-name <label> now" "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt_id:\"p3\",prompt:\"go\"}' | bash '$CONTEXT_HOOK'"
    assert_eq "" "$output"
}

@test "the prompt hook tolerates malformed input and unsafe session ids" {
    local payload
    for payload in 'garbage' '' '{}' '{"hook_event_name":"UserPromptSubmit","session_id":"../x","prompt":"go"}' '{"hook_event_name":"SessionStart","session_id":"s1"}'; do
        run bash -c "printf '%s' '$payload' | bash '$CONTEXT_HOOK'"
        assert_eq 0 "$status"
    done
    [ ! -e "$CLAUDE_STATE_DIR/x" ]
}

@test "session start prunes session state older than the retention window" {
    mkdir -p "$CLAUDE_STATE_DIR/sessions/old" "$CLAUDE_STATE_DIR/sessions/new"
    chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/sessions"
    touch -t 202601010000 "$CLAUDE_STATE_DIR/sessions/old"
    jq -nc '{hook_event_name:"SessionStart",session_id:"s1",source:"startup"}' | bash "$CONTEXT_HOOK" >/dev/null
    [ ! -e "$CLAUDE_STATE_DIR/sessions/old" ]
    [ -d "$CLAUDE_STATE_DIR/sessions/new" ]
}

make_kill_switch() {
    init_state
    mkdir -p "$CLAUDE_STATE_DIR/override"
    chmod "${2:-700}" "$CLAUDE_STATE_DIR/override"
    : >"$CLAUDE_STATE_DIR/override/done_gate.off"
    [ -z "${1:-}" ] || touch -t "$1" "$CLAUDE_STATE_DIR/override/done_gate.off"
}

@test "kill switch: a fresh owned file in a 0700 dir turns the gate off" {
    make_kill_switch
    run stop "Should I merge?"
    assert_eq "" "$output"
    assert_contains "KILL_SWITCH" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "kill switch: a file older than 24h has expired" {
    make_kill_switch 202601010000
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

stamp() { date -r "$1" +%Y%m%d%H%M.%S; }

@test "kill switch: the 24h boundary, just inside is on and just outside is off" {
    make_kill_switch "$(stamp $(($(now) - 86400 + 60)))"
    run stop "Should I merge?"
    assert_eq "" "$output"
    make_kill_switch "$(stamp $(($(now) - 86400 - 60)))"
    PID=p2
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

@test "kill switch: a future mtime is ignored" {
    make_kill_switch "$(stamp $(($(now) + 3600)))"
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

@test "kill switch: a symlinked switch file or override dir is ignored" {
    init_state
    mkdir -p "$CLAUDE_STATE_DIR/override" "$BATS_TEST_TMPDIR/real"
    chmod 700 "$CLAUDE_STATE_DIR/override" "$BATS_TEST_TMPDIR/real"
    : >"$BATS_TEST_TMPDIR/real/done_gate.off"
    ln -s "$BATS_TEST_TMPDIR/real/done_gate.off" "$CLAUDE_STATE_DIR/override/done_gate.off"
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
    rm -rf "$CLAUDE_STATE_DIR/override"
    ln -s "$BATS_TEST_TMPDIR/real" "$CLAUDE_STATE_DIR/override"
    PID=p2
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

@test "kill switch: a switch file owned by another user is ignored" {
    make_kill_switch
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/stat" <<'STAT'
#!/bin/bash
out=$(/usr/bin/stat "$@") || exit
case "$*" in (*done_gate.off*) printf '0 %s\n' "${out#* }" ;; (*) printf '%s\n' "$out" ;; esac
STAT
    chmod +x "$BATS_TEST_TMPDIR/bin/stat"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "jq -nc '{hook_event_name:\"Stop\",session_id:\"s1\",prompt_id:\"p1\",last_assistant_message:\"Should I merge?\"}' | bash '$HOOK'"
    assert_eq block "$(decision "$output")"
}

@test "kill switch: a world-readable override dir is ignored" {
    make_kill_switch "" 755
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

@test "untrusted state: a symlinked session dir requires FAILURE state" {
    mkdir -p "$CLAUDE_STATE_DIR/sessions" "$BATS_TEST_TMPDIR/evil"
    chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/sessions" "$BATS_TEST_TMPDIR/evil"
    ln -s "$BATS_TEST_TMPDIR/evil" "$SDIR"
    run stop "STATUS: COMPLETE all good"
    assert_contains "state directory is untrusted" "$(reason "$output")"
    assert_contains "STATUS: FAILURE state:" "$(reason "$output")"
    run stop "STATUS: FAILURE state: the session dir is a symlink"
    assert_eq allow "$(decision "$output")"
    ACTIVE=true
    run stop "STATUS: COMPLETE all good"
    assert_eq allow "$(decision "$output")"
    assert_contains "STATE_UNTRUSTED" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "untrusted state: a group-writable sessions dir is untrusted" {
    init_state
    chmod 770 "$CLAUDE_STATE_DIR/sessions"
    run stop "STATUS: ANSWER"
    assert_contains "untrusted" "$(reason "$output")"
}

@test "a group-writable state root is tightened to 0700" {
    init_state
    chmod 770 "$CLAUDE_STATE_DIR"
    run stop "STATUS: ANSWER"
    assert_eq allow "$(decision "$output")"
    assert_eq 700 "$(stat -f %Lp "$CLAUDE_STATE_DIR")"
}

broken_copy() {
    mkdir -p "$BATS_TEST_TMPDIR/broken"
    cp "$SCRIPTS"/*.sh "$BATS_TEST_TMPDIR/broken/"
    printf 'this is not jq (' >"$BATS_TEST_TMPDIR/broken/_done_gate.jq"
    HOOK="$BATS_TEST_TMPDIR/broken/stop__coordinator.sh"
}

@test "internal error without a merge allows the stop with a visible message" {
    broken_copy
    run stop "STATUS: ANSWER"
    assert_eq 0 "$status"
    assert_eq allow "$(decision "$output")"
    assert_contains "Stop gate error" "$(sysmsg "$output")"
}

@test "internal error with a merge in the ledger requires FAILURE" {
    broken_copy
    ledger "$(merge_rec 4016)"
    run stop "STATUS: COMPLETE fine"
    assert_eq 0 "$status"
    assert_eq block "$(decision "$output")"
    assert_contains "FAILURE gate:" "$(reason "$output")"
}

@test "relay text comes first and is joined with the gate reason in one block" {
    printf 'session=s1\ntarget=4016\nrepo=o/r\nresult=%s\nwait_cmd=bash /x/gh_monitor.sh wait 4016 --repo o/r\n' \
        "$CLAUDE_NOTIFY_TMP_DIR/none" >"$CLAUDE_NOTIFY_TMP_DIR/gh_monitor_watch_merge_x.meta"
    run stop "Should I merge?"
    r=$(reason "$output")
    assert_eq block "$(decision "$output")"
    assert_contains "PR '4016' on o/r was merged by a subagent" "${r%%Stop gate*}"
    assert_contains "Stop gate (block 1 of 3)" "$r"
}

@test "settings.json has exactly one blocking Stop hook, the coordinator with a 5s timeout, and no other Stop hook emits a decision" {
    run jq -r '.hooks.Stop[].hooks[] | .command | select(endswith("/scripts/stop__coordinator.sh") | not)' "$SETTINGS"
    assert_eq 0 "$status"
    assert_eq 1 "$(jq '[.hooks.Stop[].hooks[] | select(.command | endswith("/scripts/stop__coordinator.sh")) | select((.async // false) | not)] | length' "$SETTINGS")"
    local cmd script out
    while IFS= read -r cmd; do
        script="${BATS_TEST_DIRNAME}/../scripts/${cmd##*/}"
        out=$(jq -nc '{hook_event_name:"Stop",session_id:"s1",last_assistant_message:"Should I merge?"}' | bash "$script" 2>/dev/null)
        assert_not_contains '"decision"' "$out"
    done <<<"$output"
    assert_eq 5 "$(jq -r '.hooks.Stop[].hooks[] | select(.command | endswith("/scripts/stop__coordinator.sh")) | .timeout' "$SETTINGS")"
}

@test "settings.json wires the carry-over on UserPromptSubmit and SessionStart, the question gate, and the ConfigChange guard" {
    assert_eq 1 "$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("/scripts/prompt_context__done_gate.sh"))] | length' "$SETTINGS")"
    assert_eq "startup|resume|clear|compact" "$(jq -r '.hooks.SessionStart[] | select(any(.hooks[]; .command | endswith("/scripts/prompt_context__done_gate.sh"))) | .matcher' "$SETTINGS")"
    assert_eq AskUserQuestion "$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("/scripts/pre_tool_use__ask_gate.sh"))) | .matcher' "$SETTINGS")"
    assert_eq user_settings "$(jq -r '.hooks.ConfigChange[] | select(any(.hooks[]; .command | endswith("/scripts/config_change__guard.sh"))) | .matcher' "$SETTINGS")"
}

@test "every script referenced by settings.json exists" {
    local f
    while IFS= read -r f; do
        [ -f "${BATS_TEST_DIRNAME}/../scripts/${f##*/}" ] || { echo "missing: $f" >&2; return 1; }
    done < <(jq -r '.. | .command? // empty' "$SETTINGS" | grep -o 'scripts/[A-Za-z0-9_.-]*\.sh')
}
