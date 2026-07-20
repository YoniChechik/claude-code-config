#!/usr/bin/env bats
#
# Integration test for scripts/stop__sound.sh's decision logic.
#
# The hook takes one of two paths:
#   BLUE  : set_blue_bar + exit 0, NO chime  -> no dedup lockdir created.
#   GREEN : notify_user_attention            -> creates a notify_dedup_* lockdir.
#
# We discriminate purely by the dedup-lockdir side effect (the green path's
# chime acquires it; the blue path never reaches a chime). All state/lock files
# and the dedup lockdir are redirected into BATS_TEST_TMPDIR via
# CLAUDE_NOTIFY_TMP_DIR, and a fake `afplay` on PATH keeps the suite silent.

setup() {
    REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    HOOK="${REPO_DIR}/scripts/stop__sound.sh"

    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="itest"

    # Silent afplay shim so the green path doesn't actually chime.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/afplay"
    chmod +x "$BATS_TEST_TMPDIR/bin/afplay"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # The hook resolves the current branch with `git rev-parse` from its cwd;
    # determine it up front so we can write a matching CI state file.
    CUR_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)

    TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
}

teardown() {
    [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null || true
}

# A transcript with no async-launched agents -> background not active.
write_idle_transcript() {
    printf '%s\n' '{"type":"user","message":{"content":"hello"}}' > "$TRANSCRIPT"
}

# A transcript with one async-launched, never-terminated agent -> bg active.
write_active_agent_transcript() {
    printf '%s\n' '{"toolUseResult":{"status":"async_launched","agentId":"a0123456789abcdef"}}' > "$TRANSCRIPT"
}

# State/lock files are keyed by the composite <slot>__<sanitized_branch>;
# ci_is_active (called by the hook) globs them. Use a fixed suffix here.
STATE_KEY="testbranch"

spawn_fake_watcher() {
    bash -c 'exec -a ci_watch_fake sleep 30' </dev/null >/dev/null 2>&1 &
    WPID=$!
    disown 2>/dev/null || true
    printf '%s' "$WPID" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}__${STATE_KEY}"
}

run_hook() {
    # Run with cwd = repo so the hook's internal `git rev-parse` resolves the
    # repo's branch; invoke via the absolute hook path so the relative cwd of
    # the bats harness can't break resolution.
    echo "{\"transcript_path\":\"$TRANSCRIPT\"}" > "$BATS_TEST_TMPDIR/hook_in.json"
    ( cd "$REPO_DIR" && bash "$HOOK" < "$BATS_TEST_TMPDIR/hook_in.json" ) >/dev/null 2>&1
}

dedup_lock_count() {
    ls "$CLAUDE_NOTIFY_TMP_DIR" 2>/dev/null | grep -c notify_dedup || true
}

@test "stop decision: GREEN path (no bg, no CI) creates a chime dedup lock" {
    write_idle_transcript
    # No CI state file at all -> ci_is_active false.
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: BLUE path when CI actively running (no chime)" {
    write_idle_transcript
    printf '%s' "${CUR_BRANCH}:running:1000" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}__${STATE_KEY}"
    spawn_fake_watcher
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: BLUE path when background agent still active (no chime)" {
    write_active_agent_transcript
    # No CI state -> only the bg-agent condition drives the blue path.
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN path when CI reached a terminal state (passed)" {
    write_idle_transcript
    printf '%s' "${CUR_BRANCH}:passed:1000" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}__${STATE_KEY}"
    spawn_fake_watcher
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}
