#!/usr/bin/env bats
#
# Tests for scripts/_notify.sh — the pure/logic parts that are testable without
# a real iTerm2/TTY: ci_is_active, _dedup_should_chime, and the tab-color
# emitters (set_blue_bar / _set_tab_rgb / notify_user_attention).
#
# Strategy:
#   - Real functions are sourced and exercised (no mocking of code under test).
#   - State/lock files live in a per-test BATS_TEST_TMPDIR, fed to the code via
#     CLAUDE_NOTIFY_TMP_DIR (honored by _notify.sh) — never the real /tmp.
#   - Watcher liveness uses a REAL alive process (exec -a ci_watch_fake sleep)
#     vs a guaranteed-dead PID, so the real kill -0 / ps logic runs unmocked.
#   - The terminal device is the only genuinely-external bit we stub: we
#     redefine _resolve_target_tty to echo a FIFO that a background reader
#     drains into a capture file, so every OSC write is appended. A plain file
#     would be TRUNCATED by each `printf ... > "$target_tty"`, leaving only the
#     last write and silently voiding assertions about the earlier ones.
#
# Assertions go through assert_contains / assert_not_contains, never a bare
# `[[ ... ]]`: bash does not fire the ERR trap for the `[[` keyword, so bats
# 1.13 SWALLOWS a failing non-final `[[ ... ]]` and reports the test as ok. A
# shell function returning non-zero does fail the test.

NOTIFY_SH="${BATS_TEST_DIRNAME}/../scripts/_notify.sh"

setup() {
    # Each test gets an isolated tmp dir; redirect all state/lock/lockdir paths.
    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="testsess"

    # Silent afplay shim on PATH so the green/chime path never plays a real
    # sound during the suite (notify_user_attention backgrounds `afplay`).
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/afplay"
    chmod +x "$BATS_TEST_TMPDIR/bin/afplay"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # Source the functions under test.
    source "$NOTIFY_SH"
    # Track spawned helper PIDs so teardown can reap them.
    SPAWNED_PIDS=()
}

teardown() {
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
}

# --- Assertions ------------------------------------------------------------
# Must be functions, not `[[ ... ]]`: see the header note on bats swallowing a
# failing non-final `[[ ... ]]`.
assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    case "$2" in (*"$1"*)
        printf 'expected NOT to contain: %s\nactual: %s\n' "$1" "$2" >&2
        return 1
    ;; esac
    return 0
}

# Spawn a real, alive process whose argv contains "ci_watch" (so the ps/grep
# liveness check passes against a genuine process). Echoes its PID.
spawn_fake_watcher() {
    # The sleep only has to outlive the single ci_is_active call under test, and
    # it must stay SHORT: every call site is `$(spawn_fake_watcher)`, so the
    # SPAWNED_PIDS append below happens in the command-substitution subshell and
    # is lost — teardown cannot reap it, and bats waits for it before exiting.
    # At the original 30s that single sleep cost the suite ~30s of dead wall clock.
    bash -c 'exec -a ci_watch_fake sleep 3' </dev/null >/dev/null 2>&1 3>&- &
    local pid=$!
    disown 2>/dev/null || true
    SPAWNED_PIDS+=("$pid")
    printf '%s' "$pid"
}

# A PID that is essentially guaranteed not to exist.
dead_pid() {
    printf '%s' "999999"
}

# Override the TTY resolution so OSC writes are captured instead of going to a
# real terminal. The target is a FIFO, not a plain file: the code writes with
# `> "$target_tty"`, which truncates a regular file on every write, so a
# multi-write function (notify_user_attention emits the colors, then the title)
# would leave only its LAST write behind and every earlier assertion would be
# checked against a string that cannot contain it.
redirect_tty_to_file() {
    TTY_FIFO="$BATS_TEST_TMPDIR/tty_fifo"
    TTY_CAPTURE="$BATS_TEST_TMPDIR/tty_capture"
    rm -f "$TTY_FIFO"
    mkfifo "$TTY_FIFO"
    : > "$TTY_CAPTURE"
    # ONE long-lived reader for the whole test. 3>&- is load-bearing: bats waits
    # for its internal fd 3 to be closed by every descendant, so a reader that
    # inherits it would hang the run after the last test reports.
    cat "$TTY_FIFO" > "$TTY_CAPTURE" </dev/null 2>/dev/null 3>&- &
    TTY_READER_PID=$!
    # disown so teardown's belt-and-braces kill does not print a job-control
    # "Terminated" line into the bats output.
    disown 2>/dev/null || true
    SPAWNED_PIDS+=("$TTY_READER_PID")
    # Hold a writer open ourselves so the reader never sees EOF between the
    # separate `> "$target_tty"` writes the code under test performs. Without it
    # the reader would exit after the first write and the rest would be lost (or
    # block forever waiting for a new reader).
    exec 9>"$TTY_FIFO"
    eval "_resolve_target_tty() { printf '%s' '$TTY_FIFO'; }"
}

# Close our writer end and wait (bounded 1s-interval poll, never a bare sleep)
# for the reader to flush and exit, so TTY_CAPTURE is complete before assertions.
close_tty_capture() {
    exec 9>&-
    local i
    for i in 1 2 3 4 5; do
        kill -0 "$TTY_READER_PID" 2>/dev/null || return 0
        sleep 1
    done
    printf 'tty capture reader did not exit\n' >&2
    return 1
}

# A session runs one watcher PER BRANCH, so every fixture is keyed on a SLOT.
# The slot text is arbitrary here; only the _ci_slug / _ci_slot tests below
# assert how a real one is derived.
slot_for_branch() {
    printf '%s_%s-0123456789' "${CLAUDE_CODE_SESSION_ID}" "$1"
}

# Write "<branch>:<state>" for branch $1 with state line $2.
write_state() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_$(slot_for_branch "$1")"
}

# Write lock PID $2 for branch $1.
write_lock() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch "$1")"
}

# ---------------------------------------------------------------------------
# _ci_slug / _ci_slot — the bash half of the slot contract
# ---------------------------------------------------------------------------

@test "_ci_slug: leaves an already-safe branch name alone" {
    run _ci_slug "feat-x.1_2"
    [ "$output" = "feat-x.1_2" ]
}

@test "_ci_slug: replaces every unsafe character with an underscore" {
    run _ci_slug 'feat/a:b c&d'
    [ "$output" = "feat_a_b_c_d" ]
}

@test "_ci_slug: truncates to 40 bytes" {
    local long
    long="$(printf 'x%.0s' {1..200})"
    run _ci_slug "$long"
    [ "${#output}" -eq 40 ]
}

@test "_ci_slug: substitutes per BYTE, matching ci_watch.py's sanitize_branch" {
    # ci_watch.py works on the UTF-8 bytes. A locale-aware tr here would emit a
    # different slug for a non-ASCII branch, and the launcher and the watcher
    # would key on different files with nothing failing loudly.
    run _ci_slug 'féat/ü'
    [ "$output" = "f__at___" ]
}

@test "_ci_slot: matches ci_watch.py's slot_for exactly" {
    local expected
    expected="$(cd "${BATS_TEST_DIRNAME}/.." && uv run --quiet --with requests \
        python -c '
import sys
sys.path.insert(0, "skills/ci-watcher")
import ci_watch
print(ci_watch.slot_for("testsess", "o", "r", "féat/ü"))
')"
    [ -n "$expected" ]
    run _ci_slot "testsess" "o/r" 'féat/ü'
    [ "$output" = "$expected" ]
}

@test "_ci_slot: the same branch in two repos gets different slots" {
    local a b
    a="$(_ci_slot "testsess" "o/repo-a" "main")"
    b="$(_ci_slot "testsess" "o/repo-b" "main")"
    [ "$a" != "$b" ]
}

@test "_ci_slot: fails loudly when the hash cannot be computed" {
    # shasum is a perl script, not a coreutils binary, and is absent on many
    # minimal images. An empty hash would build a slot no watcher ever owns.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 127\n' > "$BATS_TEST_TMPDIR/bin/shasum"
    chmod +x "$BATS_TEST_TMPDIR/bin/shasum"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run _ci_slot "testsess" "o/r" "main"
    [ "$status" -ne 0 ]
    assert_contains "identity hash" "$output"
}

# ---------------------------------------------------------------------------
# _ci_watch_session_state_files — the one discovery implementation
# ---------------------------------------------------------------------------

@test "_ci_watch_session_state_files: prints nothing when the session has none" {
    run _ci_watch_session_state_files "testsess"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_ci_watch_session_state_files: prints one path per watcher" {
    write_state "feat-a" "feat-a:running"
    write_state "feat-b" "feat-b:merging"
    run _ci_watch_session_state_files "testsess"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
    assert_contains "ci_watch_state_testsess_feat-a-" "$output"
    assert_contains "ci_watch_state_testsess_feat-b-" "$output"
}

@test "_ci_watch_session_state_files: ignores another session's watchers" {
    printf 'x:running' > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_othersess_feat-a-0123456789"
    run _ci_watch_session_state_files "testsess"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_ci_watch_session_state_files: prints nothing for an empty session id" {
    run _ci_watch_session_state_files ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_ci_watch_session_state_files: a FIFO at a state path is never listed" {
    # These paths are predictable and live in a shared /tmp. A FIFO planted at
    # one of them would block the `cat` of every consumer — the 1s status-line
    # poll and ci_is_active inside the Stop hook — forever.
    mkfifo "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_testsess_feat-fifo-0123456789"
    write_state "feat-a" "feat-a:running"
    run _ci_watch_session_state_files "testsess"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
    assert_contains "feat-a-" "$output"
    assert_not_contains "feat-fifo" "$output"
}

@test "_ci_watch_session_state_files: a write_state temp file is never listed" {
    # write_state renames a temp file into place. A temp name matching this glob
    # would be discovered as a lock-less watcher and reported as a death.
    write_state "feat-a" "feat-a:running"
    printf 'feat-a:running' \
        > "$CLAUDE_NOTIFY_TMP_DIR/.ci_watch_tmp_testsess_feat-a-0123456789.aB3xYz"
    run _ci_watch_session_state_files "testsess"
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ci_is_active
# ---------------------------------------------------------------------------

@test "ci_is_active: ACTIVE when watcher alive + state running" {
    write_state "feat-x" "feat-x:running"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE for merging state too" {
    write_state "feat-x" "feat-x:merging"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE when ANY of several watchers is running" {
    # A session can watch several branches at once. One of them still running
    # is background work in progress, whatever the other ones are doing.
    write_state "feat-a" "feat-a:passed"
    write_lock "feat-a" "$(dead_pid)"
    write_state "feat-b" "feat-b:running"
    write_lock "feat-b" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE for a watcher on a DIFFERENT branch than the cwd" {
    # The branch-match requirement is gone on purpose: with several concurrent
    # PRs the shell's cwd says nothing about whether background CI is running.
    write_state "some-other-branch" "some-other-branch:running"
    write_lock "some-other-branch" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: NON-active when the notification channel is gone" {
    # Alive + running, but ci_watch.py's stdout writes are failing, so no CI
    # result will ever be reported. Counting it as active would pin the tab blue
    # and swallow the chime while nothing is left to tell the user anything.
    write_state "feat-x" "feat-x:running:monitor-detached@1757000000"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state file missing" {
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state file empty" {
    write_state "feat-x" ""
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state has no branch prefix (no colon)" {
    write_state "feat-x" "running"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state passed" {
    write_state "feat-x" "feat-x:passed"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state failed" {
    write_state "feat-x" "feat-x:failed"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state merged-passed" {
    write_state "feat-x" "feat-x:merged-passed"
    write_lock "feat-x" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when watcher PID is dead (stale running)" {
    write_state "feat-x" "feat-x:running"
    write_lock "feat-x" "$(dead_pid)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when another SLOT's watcher is the live one" {
    # Liveness is per-slot: a live watcher for feat-b must not make feat-a's
    # stale "running" state count as active.
    write_state "feat-a" "feat-a:running"
    write_lock "feat-a" "$(dead_pid)"
    write_lock "feat-b" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when lockfile missing" {
    write_state "feat-x" "feat-x:running"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when lockfile is present but empty (truncated)" {
    write_state "feat-x" "feat-x:running"
    # A crashed/half-written watcher can leave an empty lockfile: no PID to
    # kill -0, so liveness must fail rather than error out.
    write_lock "feat-x" ""
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when PID alive but args don't mention ci_watch" {
    write_state "feat-x" "feat-x:running"
    # $$ is the bats test process — alive, but its argv is not ci_watch.
    write_lock "feat-x" "$$"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when CLAUDE_CODE_SESSION_ID is empty" {
    export CLAUDE_CODE_SESSION_ID=""
    run ci_is_active
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _dedup_should_chime
# ---------------------------------------------------------------------------

@test "dedup: first call for a fresh event key chimes (returns 0) and claims a lock" {
    redirect_tty_to_file
    run _dedup_should_chime "attention"
    [ "$status" -eq 0 ]
    # The chime decision must be backed by a real atomic lock claim, not just a
    # bare return code: exactly one dedup lockdir for this key must now exist.
    run bash -c "ls -d '$CLAUDE_NOTIFY_TMP_DIR'/notify_dedup_attention_* 2>/dev/null | wc -l"
    [ "$output" -eq 1 ]
}

@test "dedup: immediate second call with same key is suppressed (returns 1)" {
    redirect_tty_to_file
    _dedup_should_chime "attention"
    run _dedup_should_chime "attention"
    [ "$status" -ne 0 ]
}

@test "dedup: different event keys do not suppress each other" {
    redirect_tty_to_file
    _dedup_should_chime "attention"
    run _dedup_should_chime "rate_limit"
    [ "$status" -eq 0 ]
}

@test "dedup: different sessions do not suppress each other" {
    redirect_tty_to_file
    CLAUDE_CODE_SESSION_ID="sessA" _dedup_should_chime "attention"
    run env CLAUDE_CODE_SESSION_ID="sessB" bash -c "
        source '$NOTIFY_SH'
        _resolve_target_tty() { printf '%s' '$TTY_CAPTURE'; }
        export -f _resolve_target_tty
        _dedup_should_chime attention"
    [ "$status" -eq 0 ]
}

@test "dedup: stale lock (older than window) is taken over and chimes again" {
    redirect_tty_to_file
    # Manually create a stale lockdir whose mtime is well past the window.
    local tty_token="${TTY_CAPTURE//\//_}"
    local lockdir="$CLAUDE_NOTIFY_TMP_DIR/notify_dedup_attention_${CLAUDE_CODE_SESSION_ID}_${tty_token}"
    mkdir -p "$lockdir"
    # Backdate the mtime to 1 hour ago (well beyond _DEDUP_WINDOW_SECONDS).
    touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-1 hour' '+%Y%m%d%H%M.%S')" "$lockdir"
    run _dedup_should_chime "attention"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tab-color emitters: set_blue_bar / _set_tab_rgb / notify_user_attention
# ---------------------------------------------------------------------------

@test "_set_tab_rgb: emits the OSC 6 three-channel sequence with given values" {
    redirect_tty_to_file
    _set_tab_rgb 12 34 56
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "6;1;bg;red;brightness;12" "$output"
    assert_contains "6;1;bg;green;brightness;34" "$output"
    assert_contains "6;1;bg;blue;brightness;56" "$output"
}

@test "set_blue_bar: emits blue RGB (0/0/255), no bell sound, no title OSC" {
    redirect_tty_to_file
    set_blue_bar
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "6;1;bg;red;brightness;0" "$output"
    assert_contains "6;1;bg;green;brightness;0" "$output"
    assert_contains "6;1;bg;blue;brightness;255" "$output"
    # No title sequence (OSC 0 "]0;").
    assert_not_contains "]0;" "$output"
    # No "waiting" title text.
    assert_not_contains "waiting" "$output"
}

@test "notify_user_attention: emits green RGB (0/255/0) and uses the session-name sidecar as the title" {
    redirect_tty_to_file
    printf 'my session' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    # No arg => legacy unconditional-green path (no background-work gating).
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "6;1;bg;red;brightness;0" "$output"
    assert_contains "6;1;bg;green;brightness;255" "$output"
    assert_contains "6;1;bg;blue;brightness;0" "$output"
    # Title is the sidecar value verbatim — never the branch name.
    assert_contains "]0;my session" "$output"
    assert_not_contains "]0;feat-x" "$output"
    assert_not_contains "waiting" "$output"
}

@test "notify_user_attention: strips embedded control bytes from the sidecar name before emitting the title" {
    redirect_tty_to_file
    # C0 (tab, newline, ESC, BEL), DEL (0x7f) and C1 (U+009B) all get stripped.
    printf 'a\tb\nc\x1bd\x07e\x7ff\xc2\x9bg' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    # The stripped, contiguous name reaches the title with none of the raw
    # control bytes surviving in between.
    assert_contains "]0;abcdefg" "$output"
    # Exactly ONE title sequence: no second, injected OSC alongside it.
    [ "$(grep -c ']0;' <<< "$output")" -eq 1 ]
}

@test "notify_user_attention: backslash-escape TEXT in the name emits no second OSC sequence" {
    redirect_tty_to_file
    # Purely printable payload — zero raw control bytes, so the control-byte
    # filter alone never saw it. The backslashes must be gone by title time.
    printf '%s' 'proj\033]0;PWNED\007' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "]0;proj033]0;PWNED007" "$output"
    assert_not_contains "\\" "$output"
}

@test "notify_user_attention: caps the title at 35 codepoints, not 35 bytes" {
    redirect_tty_to_file
    python3 -c 'print("\U0001F600"*40, end="")' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    # Exactly 35 whole emoji — never 35 bytes, never a split character.
    assert_contains "]0;$(python3 -c 'print("\U0001F600"*35, end="")')" "$output"
    assert_not_contains "$(python3 -c 'print("\U0001F600"*36, end="")')" "$output"
}

@test "notify_user_attention: no sidecar file -> no title OSC escape emitted at all" {
    redirect_tty_to_file
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "6;1;bg;green;brightness;255" "$output"
    # No title sequence at all — no branch-name fallback, no blank title.
    assert_not_contains "]0;" "$output"
}

@test "notify_user_attention: an empty sidecar file -> no title OSC escape" {
    redirect_tty_to_file
    : > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_not_contains "]0;" "$output"
}

@test "notify_user_attention: a name that sanitizes to nothing -> no title OSC escape" {
    redirect_tty_to_file
    printf '  \t\n \x1b\x07  ' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    # An empty title write would CLEAR the tab title; emit nothing instead.
    assert_not_contains "]0;" "$output"
}

@test "notify_user_attention: an empty CLAUDE_CODE_SESSION_ID -> no title OSC escape" {
    redirect_tty_to_file
    printf 'orphan name' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_"
    export CLAUDE_CODE_SESSION_ID=""
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    # The empty-suffix path must never be read as a fallback.
    assert_not_contains "]0;" "$output"
    assert_not_contains "orphan name" "$output"
}

@test "notify_user_attention: another session's sidecar name never leaks into this title" {
    redirect_tty_to_file
    printf 'other session' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_othersess"
    printf 'my session' > "$CLAUDE_NOTIFY_TMP_DIR/session_name_${CLAUDE_CODE_SESSION_ID}"
    notify_user_attention >/dev/null 2>&1
    close_tty_capture
    output="$(cat "$TTY_CAPTURE")"
    assert_contains "]0;my session" "$output"
    assert_not_contains "other session" "$output"
}

@test "set_blue_bar: does NOT create a dedup lock (background state never chimes)" {
    redirect_tty_to_file
    set_blue_bar
    run bash -c "ls '$CLAUDE_NOTIFY_TMP_DIR' | grep -c notify_dedup || true"
    [ "$output" -eq 0 ]
}
