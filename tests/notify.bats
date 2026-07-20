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
#     redefine _resolve_target_tty to echo a temp file path so OSC writes land
#     in a file we can assert on.

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

# Spawn a real, alive process whose argv contains "ci_watch" (so the ps/grep
# liveness check passes against a genuine process). Echoes its PID.
spawn_fake_watcher() {
    bash -c 'exec -a ci_watch_fake sleep 30' </dev/null >/dev/null 2>&1 &
    local pid=$!
    disown 2>/dev/null || true
    SPAWNED_PIDS+=("$pid")
    printf '%s' "$pid"
}

# A PID that is essentially guaranteed not to exist.
dead_pid() {
    printf '%s' "999999"
}

# Override the TTY resolution to a file under the test tmp dir so OSC writes
# are captured instead of going to a real terminal.
redirect_tty_to_file() {
    TTY_CAPTURE="$BATS_TEST_TMPDIR/tty_capture"
    : > "$TTY_CAPTURE"
    eval "_resolve_target_tty() { printf '%s' '$TTY_CAPTURE'; }"
}

# State files are keyed by the composite <slot>__<sanitized_branch>; ci_is_active
# globs them. Single-watcher tests use a fixed suffix.
STATE_KEY="testbranch"

write_state() {
    printf '%s' "$1" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}__${STATE_KEY}"
}

write_lock() {
    printf '%s' "$1" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}__${STATE_KEY}"
}

# Write a composite-keyed state+lock pair for a named watcher suffix.
#   $1 = key suffix, $2 = state content line, $3 = lock pid
write_watcher() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}__$1"
    printf '%s' "$3" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}__$1"
}

# Force ci_is_active to see a deterministic "current branch" by stubbing git.
stub_branch() {
    local branch="$1"
    eval "git() { if [ \"\$1 \$2\" = 'rev-parse --abbrev-ref' ]; then printf '%s\n' '$branch'; else command git \"\$@\"; fi; }"
}

# ---------------------------------------------------------------------------
# ci_is_active
# ---------------------------------------------------------------------------

@test "ci_is_active: ACTIVE when watcher alive + state running + branch matches" {
    stub_branch "feat-x"
    write_state "feat-x:running:1000"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE for merging state too" {
    stub_branch "feat-x"
    write_state "feat-x:merging:1000"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE parses legacy 2-field line (no epoch)" {
    stub_branch "feat-x"
    write_state "feat-x:running"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: ACTIVE when one of several watchers is on the current branch" {
    stub_branch "feat-x"
    # A watcher on ANOTHER branch (alive) plus one on the current branch (alive).
    write_watcher "other-1111aaaa" "other-branch:running:1000" "$(spawn_fake_watcher)"
    write_watcher "feat-x-2222bbbb" "feat-x:running:1000" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -eq 0 ]
}

@test "ci_is_active: NON-active when watchers exist only for OTHER branches" {
    stub_branch "feat-x"
    write_watcher "other-1111aaaa" "other-branch:running:1000" "$(spawn_fake_watcher)"
    write_watcher "third-3333cccc" "third-branch:merging:1000" "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when current-branch watcher is DEAD but another branch's is alive" {
    stub_branch "feat-x"
    # An alive watcher on another branch must NOT rescue a dead current-branch
    # watcher — liveness is checked per matching row, not leaked across rows.
    write_watcher "other-1111aaaa" "other-branch:running:1000" "$(spawn_fake_watcher)"
    write_watcher "feat-x-2222bbbb" "feat-x:running:1000" "$(dead_pid)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state file missing" {
    stub_branch "feat-x"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state file empty" {
    stub_branch "feat-x"
    write_state ""
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when state has no branch prefix (no colon)" {
    stub_branch "feat-x"
    write_state "running"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state passed" {
    stub_branch "feat-x"
    write_state "feat-x:passed"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state failed" {
    stub_branch "feat-x"
    write_state "feat-x:failed"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active for terminal state merged-passed" {
    stub_branch "feat-x"
    write_state "feat-x:merged-passed"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when branch mismatches" {
    stub_branch "other-branch"
    write_state "feat-x:running"
    write_lock "$(spawn_fake_watcher)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when watcher PID is dead (stale running)" {
    stub_branch "feat-x"
    write_state "feat-x:running"
    write_lock "$(dead_pid)"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when lockfile missing" {
    stub_branch "feat-x"
    write_state "feat-x:running"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when lockfile is present but empty (truncated)" {
    stub_branch "feat-x"
    write_state "feat-x:running"
    # A crashed/half-written watcher can leave an empty lockfile: no PID to
    # kill -0, so liveness must fail rather than error out.
    write_lock ""
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when PID alive but args don't mention ci_watch" {
    stub_branch "feat-x"
    write_state "feat-x:running"
    # $$ is the bats test process — alive, but its argv is not ci_watch.
    write_lock "$$"
    run ci_is_active
    [ "$status" -ne 0 ]
}

@test "ci_is_active: NON-active when CLAUDE_CODE_SESSION_ID is empty" {
    stub_branch "feat-x"
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
    run cat "$TTY_CAPTURE"
    [[ "$output" == *"6;1;bg;red;brightness;12"* ]]
    [[ "$output" == *"6;1;bg;green;brightness;34"* ]]
    [[ "$output" == *"6;1;bg;blue;brightness;56"* ]]
}

@test "set_blue_bar: emits blue RGB (0/0/255), no bell sound, no title OSC" {
    redirect_tty_to_file
    set_blue_bar
    run cat "$TTY_CAPTURE"
    [[ "$output" == *"6;1;bg;red;brightness;0"* ]]
    [[ "$output" == *"6;1;bg;green;brightness;0"* ]]
    [[ "$output" == *"6;1;bg;blue;brightness;255"* ]]
    # No title sequence (OSC 0 "]0;").
    [[ "$output" != *"]0;"* ]]
    # No "waiting" title text.
    [[ "$output" != *"waiting"* ]]
}

@test "notify_user_attention: emits green RGB (0/255/0) and a plain branch-name title" {
    redirect_tty_to_file
    stub_branch "feat-x"
    # No arg => legacy unconditional-green path (no background-work gating).
    notify_user_attention >/dev/null 2>&1
    run cat "$TTY_CAPTURE"
    [[ "$output" == *"6;1;bg;red;brightness;0"* ]]
    [[ "$output" == *"6;1;bg;green;brightness;255"* ]]
    [[ "$output" == *"6;1;bg;blue;brightness;0"* ]]
    # Title is the plain branch name — no "waiting", no emoji decorations.
    [[ "$output" == *"]0;feat-x"* ]]
    [[ "$output" != *"waiting"* ]]
}

@test "set_blue_bar: does NOT create a dedup lock (background state never chimes)" {
    redirect_tty_to_file
    set_blue_bar
    run bash -c "ls '$CLAUDE_NOTIFY_TMP_DIR' | grep -c notify_dedup || true"
    [ "$output" -eq 0 ]
}
