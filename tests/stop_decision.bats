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

# --- Transcript line builders (shapes copied from real Claude Code transcripts).
# $1 is an ISO-8601 UTC timestamp; the agent id is the same throughout so the
# events form one agent's lifecycle.
AGENT_ID="a0123456789abcdef"

# Task tool result for a background launch.
line_launch() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"status":"async_launched","agentId":"%s"}}\n' \
        "$1" "$AGENT_ID"
}

# A <task-notification> in its queue-operation form (top-level "content" string,
# with the literal \n separators the real transcript carries). $2 is the status.
line_notification() {
    printf '{"type":"queue-operation","timestamp":"%s","content":"<task-notification>\\n<task-id>%s</task-id>\\n<status>%s</status>\\n</task-notification>"}\n' \
        "$1" "$AGENT_ID" "$2"
}

# SendMessage result that restarts a stopped agent in the background. This is the
# event that has NO async_launched marker of its own.
line_resume() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"success":true,"message":"Agent \\"%s\\" had no active task; resumed from transcript in the background with your message. You'"'"'ll be notified when it finishes."}}\n' \
        "$1" "$AGENT_ID"
}

# Blocking TaskOutput result: it reaps the agent itself, so no task-notification
# is ever emitted and this is the only record that the agent stopped.
line_task_output() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"retrieval_status":"success","task":{"task_id":"%s","task_type":"local_agent","status":"%s"}}}\n' \
        "$1" "$AGENT_ID" "$2"
}

spawn_fake_watcher() {
    bash -c 'exec -a ci_watch_fake sleep 30' </dev/null >/dev/null 2>&1 &
    WPID=$!
    disown 2>/dev/null || true
    printf '%s' "$WPID" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}"
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
    printf '%s' "${CUR_BRANCH}:running" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}"
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
    printf '%s' "${CUR_BRANCH}:passed" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_${CLAUDE_CODE_SESSION_ID}"
    spawn_fake_watcher
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Resumed background agents (regression: green fired while an agent still ran)
#
# A stopped agent restarted with SendMessage runs again WITHOUT emitting a new
# async_launched marker. The old detector computed active = launched - terminated,
# so an id that had stopped once could never leave the terminated set: the Stop
# hook painted the tab GREEN and chimed while the resumed agent was still working.
# ---------------------------------------------------------------------------

@test "stop decision: BLUE when a stopped agent was RESUMED in the background" {
    {
        line_launch       "2026-07-27T17:21:37.477Z"
        line_notification "2026-07-27T17:54:33.752Z" "failed"
        line_resume       "2026-07-28T06:27:56.919Z"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN once the resumed agent finally reports completed" {
    {
        line_launch       "2026-07-27T17:21:37.477Z"
        line_notification "2026-07-27T17:54:33.752Z" "failed"
        line_resume       "2026-07-28T06:27:56.919Z"
        line_notification "2026-07-28T06:34:48.201Z" "completed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: GREEN when a resumed agent is later killed (TaskStop)" {
    # "killed" is what TaskStop emits; an unrecognized status would never clear
    # the id, pinning the tab blue and silencing the chime forever.
    {
        line_launch       "2026-07-27T17:21:37.477Z"
        line_notification "2026-07-27T17:54:33.752Z" "completed"
        line_resume       "2026-07-28T06:27:56.919Z"
        line_notification "2026-07-28T06:30:00.000Z" "killed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: GREEN when a resumed agent is reaped by a blocking TaskOutput" {
    # A blocking TaskOutput collects the result itself, so NO task-notification
    # is ever written — its task.status is the only stop record.
    {
        line_launch     "2026-07-27T17:21:37.477Z"
        line_resume     "2026-07-28T06:27:56.919Z"
        line_task_output "2026-07-28T06:29:00.000Z" "completed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: GREEN when the stop notification precedes the launch line but is newer" {
    # Transcript lines are NOT in wall-clock order: a queue-operation
    # notification is written where it was QUEUED, which can be many lines
    # BEFORE the launch it terminates. Ordering by line number instead of by
    # timestamp would resurrect this long-dead agent and pin the tab blue.
    {
        line_notification "2026-07-27T13:09:19.222Z" "completed"
        line_launch       "2026-07-27T13:09:18.460Z"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}
