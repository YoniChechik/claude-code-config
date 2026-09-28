#!/usr/bin/env bats
#
# Tests for skills/session-name/rename_session.sh -- the single
# session-name script (sanitize, no-op, atomic write; iTerm2 steps skipped outside iTerm2). The sanitize/read primitives are covered by tests/session_name.bats.

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

@test "a name matching the stored one is a no-op (exit 10)" {
    printf '%s' "already-set" >"$BATS_TEST_TMPDIR/session_name_testsess"
    run bash "$SCRIPT" "already-set"
    [ "$status" -eq 10 ]
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
