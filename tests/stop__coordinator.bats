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
    export DONE_GATE_MODE=enforce
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
reason() { printf '%s' "$1" | jq -r '.reason // ""'; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""'; }

init_state() { mkdir -p "$SDIR" && chmod 700 "$CLAUDE_STATE_DIR" "$CLAUDE_STATE_DIR/sessions" "$SDIR"; }

ledger() {
    init_state
    local rec
    for rec in "$@"; do printf '%s\n' "$rec" >>"$SDIR/ledger.jsonl"; done
}

now() { date +%s; }

merge_rec() { printf '{"kind":"merge","repo":"o/r","target":"%s","wait_cmd":"bash /x/gh_monitor.sh wait %s --repo o/r","prompt_id":"%s","ts":%s}' "$1" "$1" "${2:-$PID}" "${3:-$(($(now) - 100))}"; }

verify_rec() {
    printf '{"kind":"verify","repo":"o/r","target":"%s","merge_sha":"%s","result":"%s","reason":"r","targets":[{"name":"staging","observed_sha":"%s","probes":[{"cmd":"x","exit":%s,"matched":true}]}],"ts":%s}' \
        "$1" "$SHA" "${2:-pass}" "${3:-${SHA:0:12}}" "${4:-0}" "$(($(now) - 50))"
}

wait_task() { printf '[{"id":"%s","type":"shell","status":"%s","description":"%s","command":"%s"}]' "$1" "${2:-running}" "$3" "$4"; }

@test "every mined lazy final message is blocked by the rule named in its fixture" {
    local f rule out n=0
    for f in "$FIXTURES"/block/*.txt; do
        rule=$(basename "$f")
        rule=${rule%%__*}
        SID="fx$n"
        n=$((n + 1))
        out=$(stop "$(cat "$f")")
        assert_eq block "$(decision "$out")" || { echo "not blocked: $f" >&2; return 1; }
        assert_contains "$rule:" "$(reason "$out")" || { echo "wrong rule: $f" >&2; return 1; }
    done
    ((n >= 20))
}

@test "every legitimate human-only stop and honest status passes the gate" {
    local f out n=0
    for f in "$FIXTURES"/pass/*.txt; do
        SID="px$n"
        n=$((n + 1))
        out=$(stop "$(cat "$f")")
        assert_eq allow "$(decision "$out")" || { echo "blocked: $f: $(reason "$out")" >&2; return 1; }
    done
    ((n >= 10))
}

@test "log mode blocks nothing and logs the would-be decision per rule" {
    export DONE_GATE_MODE=log
    run stop "$(cat "$FIXTURES/block/G1__merge_handoff.txt")"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "would_block rules=G1 session=s1" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "the mode defaults to log, and a regular mode file switches it to enforce" {
    unset DONE_GATE_MODE
    run stop "Should I merge?"
    assert_eq "" "$output"
    init_state
    printf 'enforce\n' >"$CLAUDE_STATE_DIR/done_gate.mode"
    run stop "Should I merge?"
    assert_eq block "$(decision "$output")"
}

@test "a symlinked mode file is ignored and the gate stays in log mode" {
    unset DONE_GATE_MODE
    init_state
    printf 'enforce\n' >"$BATS_TEST_TMPDIR/mode"
    ln -s "$BATS_TEST_TMPDIR/mode" "$CLAUDE_STATE_DIR/done_gate.mode"
    run stop "Should I merge?"
    assert_eq "" "$output"
}

@test "a subagent stop is never gated" {
    run bash -c "jq -nc '{hook_event_name:\"Stop\",session_id:\"s1\",agent_id:\"a1\",last_assistant_message:\"Should I merge?\"}' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
}

@test "bad input never fails: exit 0 and no output" {
    run bash -c "printf 'not json' | bash '$HOOK'"
    assert_eq 0 "$status"
    assert_eq "" "$output"
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
    assert_contains "G2: PR 4016 on o/r is merged and has no staging verify result yet. Run \`bash /x/gh_monitor.sh wait 4016 --repo o/r\` with \`run_in_background: true\`" "$(reason "$output")"
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

@test "G2: a missing verify.json asks for the no-verify-config FAILURE, which then acks the merge" {
    ledger "$(merge_rec 4016 p0)" "$(verify_rec 4016 no-config)"
    run stop "STATUS: ANSWER"
    assert_contains "has no \`.claude/verify.json\` on its base branch" "$(reason "$output")"
    PID=p2
    run stop "STATUS: FAILURE no-verify-config: o/r PR 4016"
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

@test "G3: a watcher older than its TTL fails" {
    init_state
    printf '{"tasks":{"b7":%s},"pred_ack":""}' "$(($(now) - 600))" >"$SDIR/gate.json"
    TASKS=$(wait_task b7 running "[wait:x] ttl=5 poll" "x")
    run stop "STATUS: WAITING b7 x"
    assert_contains "longer than its TTL of 5 min" "$(reason "$output")"
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
    assert_contains "PR 4016 on o/r" "$c"
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
    assert_contains "PR 4016 on o/r" "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
}

@test "carry-over is silent in log mode" {
    export DONE_GATE_MODE=log
    ledger "$(merge_rec 4016 p0)"
    run bash -c "jq -nc '{hook_event_name:\"UserPromptSubmit\",session_id:\"s1\",prompt:\"hi\"}' | bash '$CONTEXT_HOOK'"
    assert_eq "" "$output"
}

@test "session start injects the session-name line and the carry-over" {
    ledger "$(merge_rec 4016 p0)"
    run bash -c "jq -nc '{hook_event_name:\"SessionStart\",session_id:\"s1\",source:\"resume\"}' | bash '$CONTEXT_HOOK'"
    c=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_eq SessionStart "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    assert_contains "Run /session-name now, and add --done '<exit predicate>'" "$c"
    assert_contains "PR 4016 on o/r" "$c"
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

@test "settings.json has exactly one blocking Stop hook, the coordinator with a 5s timeout, and no other Stop script prints a decision" {
    run jq -r '[.hooks.Stop[].hooks[] | select((.async // false) | not) | .command | select(test("decision") | not)] | .[]' "$SETTINGS"
    local cmd script deciders=()
    while IFS= read -r cmd; do
        script="${BATS_TEST_DIRNAME}/../scripts/${cmd##*/}"
        grep -q '"decision"\|decision: "block"\|decision":"block' "$script" && deciders+=("${cmd##*/}")
    done <<<"$output"
    assert_eq "stop__coordinator.sh" "${deciders[*]}"
    assert_eq 5 "$(jq -r '.hooks.Stop[].hooks[] | select(.command | endswith("/scripts/stop__coordinator.sh")) | .timeout' "$SETTINGS")"
    assert_eq 0 "$(jq -r '[.. | .command? // empty | select(test("session_name_reminder"))] | length' "$SETTINGS")"
}

@test "settings.json wires the carry-over on UserPromptSubmit and SessionStart, the question gate, and the ConfigChange guard" {
    assert_eq 1 "$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("/scripts/prompt_context__done_gate.sh"))] | length' "$SETTINGS")"
    assert_eq "startup|resume|compact" "$(jq -r '.hooks.SessionStart[] | select(any(.hooks[]; .command | endswith("/scripts/prompt_context__done_gate.sh"))) | .matcher' "$SETTINGS")"
    assert_eq AskUserQuestion "$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("/scripts/pre_tool_use__ask_gate.sh"))) | .matcher' "$SETTINGS")"
    assert_eq user_settings "$(jq -r '.hooks.ConfigChange[] | select(any(.hooks[]; .command | endswith("/scripts/config_change__guard.sh"))) | .matcher' "$SETTINGS")"
}

@test "every script referenced by settings.json exists" {
    local f
    while IFS= read -r f; do
        [ -f "${BATS_TEST_DIRNAME}/../scripts/${f##*/}" ] || { echo "missing: $f" >&2; return 1; }
    done < <(jq -r '.. | .command? // empty' "$SETTINGS" | grep -o 'scripts/[A-Za-z0-9_.-]*\.sh')
}
