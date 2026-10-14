#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../skills/session-name/rename_session.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    unset AGENT_SESSION_ID
    export CLAUDE_CODE_SESSION_ID="testsess"
    unset TERM_PROGRAM ITERM_SESSION_ID
}

@test "a fresh name is written, printed sanitized, exit 0" {
    run bash "$SCRIPT" "  my-feature  "
    [ "$status" -eq 0 ]
    [ "$output" = "my-feature" ]
    [ "$(cat "$BATS_TEST_TMPDIR/session_name_testsess")" = "my-feature" ]
    [ "$(wc -c <"$BATS_TEST_TMPDIR/session_name_testsess")" -eq 10 ]
}

@test "a name matching the stored one is a silent no-op (exit 0, no output)" {
    printf '%s' "already-set" >"$BATS_TEST_TMPDIR/session_name_testsess"
    run bash "$SCRIPT" "already-set"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a name that sanitizes to empty exits 1 and writes nothing" {
    run bash "$SCRIPT" "   "
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/session_name_testsess" ]
}

@test "caps at 35 Unicode codepoints, not bytes" {
    run bash "$SCRIPT" "$(printf 'é%.0s' $(seq 1 40))"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 35 ]
}

@test "write is atomic -- a failure leaves no partial file behind" {
    chmod 000 "$BATS_TEST_TMPDIR"
    run bash "$SCRIPT" "my-feature"
    chmod 755 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/session_name_testsess" ]
}

@test "fails without a session id" {
    unset CLAUDE_CODE_SESSION_ID
    run bash "$SCRIPT" "my-feature"
    [ "$status" -eq 1 ]
}

@test "AGENT_SESSION_ID works as a fallback" {
    unset CLAUDE_CODE_SESSION_ID
    export AGENT_SESSION_ID="otherid"
    run bash "$SCRIPT" "my-feature"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/session_name_otherid" ]
}

@test "--done appends one predicate record to a 0700 session ledger" {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    run bash "$SCRIPT" "my-feature" --done 'cmd:curl -fsS https://x/ping' --done 'merged:sunsay/core#1'
    [ "$status" -eq 0 ]
    [ "$output" = "my-feature" ]
    local dir="$CLAUDE_STATE_DIR/sessions/$CLAUDE_CODE_SESSION_ID"
    [ "$(stat -f %Lp "$dir" 2>/dev/null || stat -c %a "$dir")" = "700" ]
    [ "$(wc -l <"$dir/ledger.jsonl")" -eq 1 ]
    run jq -r '[.kind, (.items | length), .items[1], (.sha256 | length), (.ts | type)] | @tsv' "$dir/ledger.jsonl"
    [ "$output" = "$(printf 'predicate\t2\tmerged:sunsay/core#1\t64\tnumber')" ]
}

@test "--done with an unchanged name and predicate is silent and appends nothing" {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    local ledger="$CLAUDE_STATE_DIR/sessions/$CLAUDE_CODE_SESSION_ID/ledger.jsonl"
    bash "$SCRIPT" "my-feature" --done 'x' >/dev/null
    run bash "$SCRIPT" "my-feature" --done ' x '
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l <"$ledger")" -eq 1 ]
    run bash "$SCRIPT" "my-feature" --done 'y'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l <"$ledger")" -eq 2 ]
}

@test "--done with only blank items exits 1" {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    run bash "$SCRIPT" "my-feature" --done '   '
    [ "$status" -eq 1 ]
    [[ "$output" == *"predicate is empty"* ]]
}

@test "--done refuses a symlinked state dir" {
    mkdir -p "$BATS_TEST_TMPDIR/real"
    ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/state"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    run bash "$SCRIPT" "my-feature" --done 'x'
    [ "$status" -eq 1 ]
    [[ "$output" == *"untrusted"* ]]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/real")" ]
}

@test "--done refuses an unsafe session id" {
    export CLAUDE_CODE_SESSION_ID="bad.id"
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    run bash "$SCRIPT" "my-feature" --done 'x'
    [ "$status" -eq 1 ]
    [ ! -e "$CLAUDE_STATE_DIR/sessions/bad.id" ]
}

@test "--done without a value or an unknown flag exits 2" {
    run bash "$SCRIPT" "my-feature" --done
    [ "$status" -eq 2 ]
    run bash "$SCRIPT" "my-feature" --bogus
    [ "$status" -eq 2 ]
}

@test "no argument exits 2 with usage" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "iTerm2: types /rename into the \$ITERM_SESSION_ID session, then a lone Enter, without focusing" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\ncat >>"%s/osa.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/osascript"
    chmod +x "$BATS_TEST_TMPDIR/bin/osascript"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t0p0:ABC-GUID" \
        run bash "$SCRIPT" 'my "x"'
    [ "$status" -eq 0 ]
    local log="$BATS_TEST_TMPDIR/osa.log"
    grep -q 'unique ID of s is "ABC-GUID"' "$log"
    grep -qF 'writeTo("/rename my \"x\"", false)' "$log"
    grep -qF 'writeTo("", true)' "$log"
    ! grep -qE 'activate|select |System Events|key code' "$log"
}
