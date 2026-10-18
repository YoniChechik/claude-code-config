#!/usr/bin/env bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
HOOK="$SCRIPTS/post_tool_use__probe_ledger.sh"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures/probe_ledger"
SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

setup() {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    LEDGER_GLOB="$CLAUDE_STATE_DIR/sessions"
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
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

feed() { bash "$HOOK" <"$1"; }

last() { tail -n 1 "$CLAUDE_STATE_DIR/sessions/${2:-s1}/ledger.jsonl" | jq -r "$1"; }

count() { if [ -f "$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl" ]; then wc -l <"$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl" | tr -d ' '; else echo 0; fi; }

bash_event() {
    jq -nc --arg c "$1" --arg o "${2:-}" --arg e "${3:-PostToolUse}" \
        '{hook_event_name: $e, session_id: "s1", prompt_id: "p1", tool_name: "Bash", tool_input: {command: $c}, tool_use_id: "t1"}
        + (if $e == "PostToolUse" then {tool_response: {stdout: $o, stderr: ""}} else {error: $o, is_interrupt: false} end)' \
        >"$BATS_TEST_TMPDIR/ev.json"
    feed "$BATS_TEST_TMPDIR/ev.json"
}

ro_of() { bash_event "$1" >/dev/null; last .ro; }

@test "captured Bash success records exit 0, ro, prompt_id, tool_use_id, ts_ms and a hash" {
    run feed "$FIXTURES/bash_success.json"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    local sid
    sid=$(jq -r .session_id "$FIXTURES/bash_success.json")
    assert_eq probe "$(last .kind "$sid")"
    assert_eq 0 "$(last .exit "$sid")"
    assert_eq echo "$(last .bin "$sid")"
    assert_eq "echo capture-ok" "$(last .cmd "$sid")"
    assert_eq "$(jq -r .prompt_id "$FIXTURES/bash_success.json")" "$(last .prompt_id "$sid")"
    assert_eq "$(jq -r .tool_use_id "$FIXTURES/bash_success.json")" "$(last .tool_use_id "$sid")"
    [[ $(last .ts_ms "$sid") =~ ^[0-9]{13}$ ]]
    [[ $(last .out_sha256 "$sid") =~ ^[0-9a-f]{64}$ ]]
    assert_eq capture-ok "$(last .out_excerpt "$sid")"
}

@test "captured Bash failure records the parsed exit code and the error excerpt, with the rtk prefix stripped" {
    feed "$FIXTURES/bash_failure.json"
    local sid
    sid=$(jq -r .session_id "$FIXTURES/bash_failure.json")
    assert_eq 1 "$(last .exit "$sid")"
    assert_eq ls "$(last .bin "$sid")"
    assert_eq "ls /nonexistent" "$(last .cmd "$sid")"
    assert_contains "No such file or directory" "$(last .out_excerpt "$sid")"
}

@test "captured Read, Grep and WebFetch failure record cmd and bin" {
    local f sid
    for f in read grep webfetch_failure; do feed "$FIXTURES/$f.json"; done
    sid=$(jq -r .session_id "$FIXTURES/read.json")
    run jq -rs 'map("\(.bin)|\(.cmd)|\(.exit)|\(.ro)") | join("\n")' "$CLAUDE_STATE_DIR/sessions/$sid/ledger.jsonl"
    assert_contains "Read|Read /tmp/capture/sample.txt|0|true" "$output"
    assert_contains "Grep|Grep hello /tmp/capture|0|true" "$output"
    assert_contains "WebFetch|WebFetch https://example.com|1|true" "$output"
}

@test "captured subagent Bash records agent_id and the parent prompt_id" {
    feed "$FIXTURES/subagent_bash.json"
    local sid
    sid=$(jq -r .session_id "$FIXTURES/subagent_bash.json")
    assert_eq "$(jq -r .agent_id "$FIXTURES/subagent_bash.json")" "$(last .agent_id "$sid")"
    assert_eq "$(jq -r .prompt_id "$FIXTURES/subagent_bash.json")" "$(last .prompt_id "$sid")"
}

@test "captured Linear get_issue records a fact with the identifier and state name" {
    feed "$FIXTURES/mcp_linear_get_issue.json"
    local sid
    sid=$(jq -r .session_id "$FIXTURES/mcp_linear_get_issue.json")
    assert_eq DEVPUB-560 "$(last .fact.linear "$sid")"
    assert_eq "Approved by Product" "$(last .fact.state "$sid")"
    assert_eq true "$(last .ro "$sid")"
}

@test "PostToolUseFailure with Exit code 2 records exit 2 and an excerpt" {
    bash_event "ls /x" $'Exit code 2\nls: /x: No such file or directory' PostToolUseFailure
    assert_eq 2 "$(last .exit)"
    assert_contains "No such file" "$(last .out_excerpt)"
}

@test "an interrupted call records exit -1 and interrupt true" {
    jq -nc '{hook_event_name: "PostToolUseFailure", session_id: "s1", tool_name: "Bash", tool_input: {command: "sleep 100"}, error: "Interrupted", is_interrupt: true, tool_use_id: "t9"}' >"$BATS_TEST_TMPDIR/ev.json"
    feed "$BATS_TEST_TMPDIR/ev.json"
    assert_eq -1 "$(last .exit)"
    assert_eq true "$(last .interrupt)"
}

@test "MCP read verbs are ro and write verbs are not" {
    jq -nc '{hook_event_name: "PostToolUse", session_id: "s1", tool_name: "mcp__linear__list_issues", tool_input: {limit: 1}, tool_response: [{type: "text", text: "[]"}], tool_use_id: "m1"}' >"$BATS_TEST_TMPDIR/ev.json"
    feed "$BATS_TEST_TMPDIR/ev.json"
    assert_eq true "$(last .ro)"
    assert_eq 'mcp__linear__list_issues {"limit":1}' "$(last .cmd)"
    jq -nc '{hook_event_name: "PostToolUse", session_id: "s1", tool_name: "mcp__linear__save_issue", tool_input: {id: "X-1"}, tool_response: [{type: "text", text: "{}"}], tool_use_id: "m2"}' >"$BATS_TEST_TMPDIR/ev.json"
    feed "$BATS_TEST_TMPDIR/ev.json"
    assert_eq false "$(last .ro)"
}

@test "action tools are skipped" {
    local t
    for t in Edit Write NotebookEdit TodoWrite Agent Task Skill ToolSearch AskUserQuestion ExitPlanMode; do
        jq -nc --arg t "$t" '{hook_event_name: "PostToolUse", session_id: "s1", tool_name: $t, tool_input: {}, tool_response: {}}' >"$BATS_TEST_TMPDIR/ev.json"
        run feed "$BATS_TEST_TMPDIR/ev.json"
        assert_eq 0 "$status"
        assert_eq "" "$output"
    done
    assert_eq 0 "$(count)"
}

@test "flag order and whitespace normalize to the same cmd, and prefixes are stripped for bin" {
    bash_event "ls -l -a  x"
    local a
    a=$(last .cmd)
    bash_event "ls -a -l x"
    assert_eq "$a" "$(last .cmd)"
    local c
    for c in "sudo ls x" "VAR=1 ls x" "rtk proxy ls x" "rtk ls x" "timeout 5 ls x" "env ls x"; do
        bash_event "$c"
        assert_eq ls "$(last .bin)" || { echo "prefix: $c" >&2; return 1; }
    done
}

@test "writes and compound commands are not read-only" {
    local c
    for c in "git push" "curl -X POST https://x" "curl -o f https://x" "curl -sSo f https://x" "curl --data a https://x" \
        "echo x > f" "cat x; git push" 'cat "$(rm f)"' 'cat `rm f`' "find . -delete" "find . -exec rm {} +" \
        "git -C x config --global a b" "ls | sh" "ls && rm x" "ls || rm x" "ls &" "cat <(rm x)" "gh pr merge 1" \
        "gh api -X POST repos/x" "gh api -XPOST x" "gh api repos/x -f a=b" "yq -i .a f" "ls | sort -o f" $'ls\nrm x' "cat x >> f"; do
        assert_eq false "$(ro_of "$c")" || { echo "should not be ro: $c" >&2; return 1; }
    done
}

@test "plain reads and filtered pipelines are read-only" {
    local c
    for c in "gh pr view 1 | jq .state" "ls 2>&1" "ls >/dev/null 2>&1" "git log --oneline" "rtk git status" "curl -sS https://x" \
        "gh api repos/x -X GET" 'rg "a|b" src' "jq '.a | .b' f" "cat f | grep x | wc -l"; do
        assert_eq true "$(ro_of "$c")" || { echo "should be ro: $c" >&2; return 1; }
    done
}

@test "secrets are redacted in the excerpt" {
    bash_event "cat f" "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 Authorization: Bearer abc123secret sk-live_0123456789abcdef"
    local e
    e=$(last .out_excerpt)
    assert_not_contains ghp_abcdef "$e"
    assert_not_contains abc123secret "$e"
    assert_not_contains sk-live "$e"
    assert_contains "<redacted>" "$e"
}

@test "a 1 MB stdout is hashed in full and stored only as a truncated excerpt" {
    head -c 1048576 /dev/zero | tr '\0' a >"$BATS_TEST_TMPDIR/big"
    jq -nc --rawfile o "$BATS_TEST_TMPDIR/big" '{hook_event_name: "PostToolUse", session_id: "s1", tool_name: "Bash", tool_input: {command: "cat big"}, tool_response: {stdout: $o, stderr: ""}, tool_use_id: "b1"}' >"$BATS_TEST_TMPDIR/ev.json"
    local start=$EPOCHREALTIME
    feed "$BATS_TEST_TMPDIR/ev.json"
    echo "1 MB probe took $(echo "$EPOCHREALTIME - $start" | bc) s" >&3
    assert_eq true "$(last .out_truncated)"
    (($(last '.out_excerpt | length') < 2100))
    (($(tail -n 1 "$CLAUDE_STATE_DIR/sessions/s1/ledger.jsonl" | wc -c) < 3000))
    local want
    want=$({ cat "$BATS_TEST_TMPDIR/big"; printf '\n'; } | shasum -a 256 | cut -d' ' -f1)
    assert_eq "$want" "$(last .out_sha256)"
}

@test "missing session id and bad JSON exit 0 with no output and no ledger" {
    local p
    for p in 'not json' '' '{}' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' '[]'; do
        run bash -c "printf '%s' '$p' | bash '$HOOK'"
        assert_eq 0 "$status"
        assert_eq "" "$output"
    done
    [ ! -d "$LEDGER_GLOB" ] || [ -z "$(ls -A "$LEDGER_GLOB")" ]
}

@test "an unsafe session id is not written and is logged as untrusted" {
    jq -nc '{hook_event_name: "PostToolUse", session_id: "../x", tool_name: "Bash", tool_input: {command: "ls"}, tool_response: {stdout: "", stderr: ""}}' >"$BATS_TEST_TMPDIR/ev.json"
    run feed "$BATS_TEST_TMPDIR/ev.json"
    assert_eq 0 "$status"
    assert_eq "" "$output"
    assert_contains "STATE_UNTRUSTED" "$(cat "$CLAUDE_HOOK_LOG_DIR/hooks.log")"
}

@test "settings has exactly one sync probe hook in PostToolUse and in PostToolUseFailure, with no matcher" {
    local ev
    for ev in PostToolUse PostToolUseFailure; do
        assert_eq 1 "$(jq --arg e "$ev" '[.hooks[$e][] | select(.matcher == null) | .hooks[] | select(.command | endswith("/scripts/post_tool_use__probe_ledger.sh")) | select((.async // false) | not)] | length' "$SETTINGS")"
        assert_eq 1 "$(jq --arg e "$ev" '[.hooks[$e][] | .hooks[] | select(.command | endswith("/scripts/post_tool_use__probe_ledger.sh"))] | length' "$SETTINGS")"
    done
}

@test "a tar list piped into grep is read-only and records the pipeline as typed" {
    local typed="tar tzf /tmp/x/pysweph-2.10.3.6.tar.gz | grep -E 'swecl.c|swehouse.c|pyswisseph.c'"
    bash_event "$typed"
    assert_eq true "$(last .ro)"
    assert_eq null "$(last .ro_reason)"
    assert_eq tar "$(last .bin)"
    local want
    want=$(jq -nr --arg c "$typed" -L "$SCRIPTS" 'include "_probe_common"; bash_cmd($c)')
    assert_eq "$want" "$(last .cmd)"
    assert_eq "tar tzf /tmp/x/pysweph-2.10.3.6.tar.gz | grep 'swecl.c|swehouse.c|pyswisseph.c' -E" "$(last .cmd)"
}

@test "rtk prefixes and flag order normalize per pipe stage" {
    bash_event "tar tzf a.tgz | rtk grep -E 'x|y' | rtk proxy head -n 3"
    local a
    a=$(last .cmd)
    assert_eq "tar tzf a.tgz | grep 'x|y' -E | head 3 -n" "$a"
    bash_event "rtk tar tzf a.tgz | grep -E 'x|y' | head -n 3"
    assert_eq "$a" "$(last .cmd)"
    assert_eq true "$(last .ro)"
}

@test "read-only allowlist additions" {
    local c
    for c in "tar -tvf a.tar" "tar --list -f a.tar" "unzip -l a.zip" "unzip -Z -1 a.zip" "zipinfo a.zip" "strings bin | grep x" \
        "du -sh ." "df -h" "realpath x" "readlink -f x" "type ls" "nl f" "column -t f" "basename /a/b" "dirname /a/b" "pwd" \
        "xxd -l 64 f" "xxd f | head" "sed -n '1,20p' f" "sed -n 5p f" "cat f | sed -n '2,4p'" "cut -d, -f1 f" "tr a b" "sort f | uniq -c"; do
        assert_eq true "$(ro_of "$c")" || { echo "should be ro: $c" >&2; return 1; }
    done
}

@test "write modes of the new bins stay non-read-only with a reason" {
    local c
    for c in "tar xzf a.tgz" "tar czf a.tgz d" "tar -xf a.tar" "tar tf a.tgz --to-command=sh" "tar -tf host:a.tar" "sed -i s/a/b/ f" \
        "sed -n '1p' -i f" "sed -n 's/a/b/w out' f" "xxd -r f" "xxd f out" "unzip a.zip" "unzip -o a.zip" "awk 1 f" "printf x" \
        "ls | tee f" "ls; rm x" "ls && mv a b" 'cat "$(rm f)"' "tar tf a.tar > l"; do
        assert_eq false "$(ro_of "$c")" || { echo "should not be ro: $c" >&2; return 1; }
        [ "$(last .ro_reason)" != null ] || { echo "no reason: $c" >&2; return 1; }
    done
}

@test "ro_reason names the cause" {
    bash_event "zcat a.gz | grep x"
    assert_eq "\`zcat\`: not in read-only allowlist" "$(last .ro_reason)"
    bash_event "cat x; ls"
    assert_eq "contains \`;\`" "$(last .ro_reason)"
    bash_event "ls | sh"
    assert_eq "\`sh\`: not a read-only pipe filter" "$(last .ro_reason)"
    bash_event "tar xzf a.tgz"
    assert_eq "\`tar\`: not list mode (\`t\` or \`--list\`)" "$(last .ro_reason)"
}
