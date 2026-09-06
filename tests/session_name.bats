#!/usr/bin/env bats
#
# Tests for the session-name feature's SHARED implementation:
#   - _sanitize_and_cap  (scripts/_notify.sh) — the one sanitize contract
#   - _session_name_read (scripts/_notify.sh) — the one sidecar reader
#   - scripts/status_line.sh — the second consumer of both, exercised as a real
#     subprocess with a hook JSON payload on stdin (it needs no other harness).
#
# Three of these tests pin CONFIRMED, reproduced bugs and must never be
# weakened:
#   1. "backslash-escape text" — a name of purely printable characters such as
#      `\033]0;PWNED\007` used to be turned back into a real OSC escape by the
#      final `printf '%b'` render, so sanitizing raw control bytes alone was
#      not enough.
#   2. "oversized sidecar"     — a multi-megabyte file used to exceed ARG_MAX as
#      a `python3 -c` argv and abort the whole status line (exit 126).
#   3. "invalid UTF-8 byte"    — a lone 0x9d decoded to a surrogate that the
#      codepoint filter missed and that crashed with UnicodeEncodeError.
#
# Assertions go through assert_contains / assert_equals rather than a bare
# `[[ ... ]]`: bash does not fire the ERR trap for the `[[` keyword, so bats
# SWALLOWS a failing non-final `[[ ... ]]` and reports the test as ok.

NOTIFY_SH="${BATS_TEST_DIRNAME}/../scripts/_notify.sh"
STATUS_LINE_SH="${BATS_TEST_DIRNAME}/../scripts/status_line.sh"

setup() {
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="testsess"
    # A non-git directory with a stable basename, so status_line.sh's repo-name
    # fallback is deterministic ("myrepo") across machines.
    WORKDIR="$BATS_TEST_TMPDIR/myrepo"
    mkdir -p "$WORKDIR"
    source "$NOTIFY_SH"
}

assert_equals() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %q\nactual:   %q\n' "$1" "$2" >&2
    return 1
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %q\nactual: %q\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in (*"$1"*)
        printf 'expected NOT to contain: %q\nactual: %q\n' "$1" "$2" >&2
        return 1
    ;; esac
    return 0
}

# Write $2 into the sidecar file for session id $1, LITERALLY — '%s', never a
# format string, so a payload like 'proj\033]0;x' stays printable backslash
# TEXT (which is the whole point of the injection tests) instead of being
# turned into real control bytes by printf itself.
write_sidecar() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${1}"
}

# Run status_line.sh as a real subprocess for a given session id. Stdout lands
# in $output, the exit code in $status (bats' `run`).
run_status_line() {
    local slot="$1"
    run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"$WORKDIR\"},\"session_id\":\"$slot\"}' | bash '$STATUS_LINE_SH'"
}

# ---------------------------------------------------------------------------
# _sanitize_and_cap — the shared contract
# ---------------------------------------------------------------------------

@test "_sanitize_and_cap: a plain short label passes through unchanged" {
    assert_equals "my session" "$(_sanitize_and_cap 'my session')"
}

@test "_sanitize_and_cap: strips raw C0 control bytes (tab, newline, ESC, BEL)" {
    assert_equals "abcde" "$(_sanitize_and_cap "$(printf 'a\tb\nc\x1bd\x07e')")"
}

@test "_sanitize_and_cap: strips DEL (0x7f) and C1 (0x80-0x9f) characters" {
    # \xc2\x9b is the UTF-8 encoding of U+009B (C1 CSI); \x7f is DEL.
    assert_equals "ab" "$(_sanitize_and_cap "$(printf 'a\x7f\xc2\x9bb')")"
}

@test "_sanitize_and_cap: strips backslashes so escape TEXT cannot be re-expanded" {
    # BLOCKING regression: purely printable input, zero raw control bytes.
    local got
    got=$(_sanitize_and_cap 'proj\033]0;PWNED\007')
    assert_not_contains '\' "$got"
    assert_equals "proj033]0;PWNED007" "$got"
}

@test "_sanitize_and_cap: trims leading and trailing whitespace" {
    assert_equals "trimmed" "$(_sanitize_and_cap '   trimmed   ')"
}

@test "_sanitize_and_cap: caps at 35 codepoints (36 ASCII chars -> 35)" {
    local got
    got=$(_sanitize_and_cap "$(printf 'a%.0s' $(seq 36))")
    assert_equals 35 "${#got}"
}

@test "_sanitize_and_cap: caps on a CODEPOINT boundary, not a byte one" {
    # 40 astral emoji (4 bytes each) must become exactly 35 whole emoji.
    local name got count
    name=$(python3 -c 'print("\U0001F600"*40, end="")')
    got=$(_sanitize_and_cap "$name")
    count=$(printf '%s' "$got" | python3 -c 'import sys; s=sys.stdin.buffer.read().decode(); print(len(s), s.count("\U0001F600"))')
    assert_equals "35 35" "$count"
}

@test "_sanitize_and_cap: an invalid UTF-8 byte is dropped, not crashed on" {
    # BLOCKING regression: a lone 0x9d used to decode to a surrogate the
    # codepoint filter missed, then raise UnicodeEncodeError on output.
    local got
    got=$(_sanitize_and_cap "$(printf 'evil\x9dTITLE')" 2>&1)
    assert_equals "evilTITLE" "$got"
}

@test "_sanitize_and_cap: input that sanitizes to nothing yields the empty string" {
    assert_equals "" "$(_sanitize_and_cap "$(printf '  \t\n \x1b\x07 ')")"
}

# ---------------------------------------------------------------------------
# _session_name_read — the shared sidecar reader
# ---------------------------------------------------------------------------

@test "_session_name_read: an empty session id reads nothing" {
    assert_equals "" "$(_session_name_read "")"
}

@test "_session_name_read: a missing sidecar file reads nothing" {
    assert_equals "" "$(_session_name_read "nosuchslot")"
}

@test "_session_name_read: a present-but-empty sidecar file reads nothing" {
    : > "$CLAUDE_NOTIFY_TMP_DIR/session_name_emptyslot"
    assert_equals "" "$(_session_name_read "emptyslot")"
}

@test "_session_name_read: a sidecar whose content sanitizes away reads nothing" {
    write_sidecar sanitizeaway "$(printf '  \t \x1b\x07  ')"
    assert_equals "" "$(_session_name_read "sanitizeaway")"
}

@test "_session_name_read: an oversized sidecar degrades to a capped name, never a crash" {
    # BLOCKING regression: this used to exceed ARG_MAX as a python3 -c argv.
    python3 -c 'print("A"*3000000, end="")' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_bigslot"
    local got
    got=$(_session_name_read "bigslot")
    assert_equals 35 "${#got}"
}

@test "_session_name_read: a FIFO at the sidecar path reads nothing instead of blocking" {
    mkfifo "$CLAUDE_NOTIFY_TMP_DIR/session_name_fifoslot"
    assert_equals "" "$(_session_name_read "fifoslot")"
}

@test "_session_name_read: two session ids do not read each other's name" {
    write_sidecar sess_a 'name for A'
    write_sidecar sess_b 'name for B'
    assert_equals "name for A" "$(_session_name_read "sess_a")"
    assert_equals "name for B" "$(_session_name_read "sess_b")"
}

@test "_display_title: reads the current session's name" {
    write_sidecar "$CLAUDE_CODE_SESSION_ID" 'the title'
    assert_equals "the title" "$(_display_title)"
}

@test "_display_title: an empty CLAUDE_CODE_SESSION_ID yields no title" {
    write_sidecar "$CLAUDE_CODE_SESSION_ID" 'the title'
    export CLAUDE_CODE_SESSION_ID=""
    assert_equals "" "$(_display_title)"
}

# ---------------------------------------------------------------------------
# status_line.sh — the second consumer, run as a real subprocess
# ---------------------------------------------------------------------------

@test "status_line.sh: a stored session name renders as 'repo / name'" {
    write_sidecar slot1 'my session'
    run_status_line slot1
    [ "$status" -eq 0 ]
    assert_contains "myrepo / my session" "$output"
}

@test "status_line.sh: no sidecar renders the repo name alone, no branch fallback" {
    run_status_line slot_none
    [ "$status" -eq 0 ]
    assert_contains "myrepo" "$output"
    assert_not_contains " / " "$output"
}

@test "status_line.sh: backslash-escape TEXT in a name never becomes a real escape" {
    # BLOCKING regression: `printf '%b'` used to convert this printable-only
    # payload into a genuine ESC ] 0 ; PWNED BEL title-setting sequence.
    write_sidecar slot_inj 'proj\033]0;PWNED\007'
    run_status_line slot_inj
    [ "$status" -eq 0 ]
    # No real OSC introducer (ESC ]) and no BEL terminator anywhere. The
    # script's own color codes are ESC [ , so this cannot false-negative.
    assert_not_contains "$(printf '\033]')" "$output"
    assert_not_contains "$(printf '\a')" "$output"
    # The payload still shows, inert, with its backslashes removed.
    assert_contains "proj033]0;PWNED007" "$output"
}

@test "status_line.sh: an oversized sidecar file does not abort the status line" {
    # BLOCKING regression: this used to exit 126 with "Argument list too long"
    # and render only "(status error)".
    python3 -c 'print("A"*3000000, end="")' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_slot_big"
    run_status_line slot_big
    [ "$status" -eq 0 ]
    assert_not_contains "status error" "$output"
    assert_contains "myrepo / AAAAA" "$output"
}

@test "status_line.sh: an invalid UTF-8 byte in a name does not abort the status line" {
    # BLOCKING regression: this used to raise UnicodeEncodeError and exit 1.
    write_sidecar slot_c1 "$(printf 'evil\x9dTITLE')"
    run_status_line slot_c1
    [ "$status" -eq 0 ]
    assert_not_contains "status error" "$output"
    assert_contains "myrepo / evilTITLE" "$output"
}

@test "status_line.sh: a FIFO at the sidecar path does not hang the status line" {
    mkfifo "$CLAUDE_NOTIFY_TMP_DIR/session_name_slot_fifo"
    run_status_line slot_fifo
    [ "$status" -eq 0 ]
    assert_not_contains " / " "$output"
}
