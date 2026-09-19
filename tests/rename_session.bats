#!/usr/bin/env bats
#
# Tests for skills/session-name/rename_session.sh -- the extracted resolve/
# write pair for the session-name skill. The underlying sanitize/read
# primitives (_sanitize_and_cap, _session_name_read) are already covered in
# depth by tests/session_name.bats; this file only covers this script's own
# orchestration: subcommand dispatch, the no-op exit code, the session-id
# fallback, and the atomic write.

SCRIPT="${BATS_TEST_DIRNAME}/../skills/session-name/rename_session.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    unset AGENT_SESSION_ID
    export CLAUDE_CODE_SESSION_ID="testsess"
}

@test "resolve: a fresh name exits 0 and prints the sanitized name" {
    run bash "$SCRIPT" resolve "  my-feature  "
    [ "$status" -eq 0 ]
    [ "$output" = "my-feature" ]
}

@test "resolve: a candidate matching the stored name is a no-op (exit 10)" {
    printf '%s' "already-set" >"$BATS_TEST_TMPDIR/session_name_testsess"
    run bash "$SCRIPT" resolve "already-set"
    [ "$status" -eq 10 ]
    [ "$output" = "already-set" ]
}

@test "resolve: a candidate that sanitizes to empty exits 1" {
    run bash "$SCRIPT" resolve "   "
    [ "$status" -eq 1 ]
}

@test "resolve: caps at 35 Unicode codepoints, not bytes" {
    # 40 multi-byte characters (é, 2 bytes each in UTF-8) -- a byte-slice at
    # 35 would corrupt the 18th character; a codepoint cap keeps exactly 35
    # whole characters.
    local name
    name=$(printf 'é%.0s' $(seq 1 40))
    run bash "$SCRIPT" resolve "$name"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 35 ]
}

@test "write: creates the sidecar file with exactly the given name, no trailing newline" {
    run bash "$SCRIPT" write "my-feature"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/session_name_testsess")" = "my-feature" ]
    [ "$(wc -c <"$BATS_TEST_TMPDIR/session_name_testsess")" -eq 10 ]
}

@test "write: is atomic -- a failure leaves no partial file behind" {
    # Make CLAUDE_NOTIFY_TMP_DIR unwritable so mktemp fails before any write.
    chmod 000 "$BATS_TEST_TMPDIR"
    run bash "$SCRIPT" write "my-feature"
    chmod 755 "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/session_name_testsess" ]
}

@test "resolve and write both fail without a session id (neither var set)" {
    unset CLAUDE_CODE_SESSION_ID
    run bash "$SCRIPT" resolve "my-feature"
    [ "$status" -eq 1 ]
    run bash "$SCRIPT" write "my-feature"
    [ "$status" -eq 1 ]
}

@test "AGENT_SESSION_ID works as a fallback when CLAUDE_CODE_SESSION_ID is unset" {
    unset CLAUDE_CODE_SESSION_ID
    export AGENT_SESSION_ID="otherid"
    run bash "$SCRIPT" write "my-feature"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/session_name_otherid" ]
}

@test "an unrecognized subcommand exits 2 with a usage message" {
    run bash "$SCRIPT" bogus "x"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}
