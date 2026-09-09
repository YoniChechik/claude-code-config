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

# A <task-notification> carrying the <tool-use-id> real transcripts include. Both
# copies of one notification share it, which is what lets the detector collapse
# them. $1 timestamp, $2 status, $3 tool-use-id.
line_notification_tuid() {
    printf '{"type":"queue-operation","timestamp":"%s","content":"<task-notification>\\n<task-id>%s</task-id>\\n<tool-use-id>%s</tool-use-id>\\n<status>%s</status>\\n</task-notification>"}\n' \
        "$1" "$AGENT_ID" "$3" "$2"
}

# A SendMessage resume with a caller-supplied message body, for exercising the
# real second phrasing and the needle contract. $1 timestamp, $2 message.
line_resume_msg() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"success":true,"message":"%s"}}\n' \
        "$1" "$2"
}

# --- Non-agent background work -------------------------------------------
# The transcript records THREE kinds of background launch, each with its own
# result shape and NONE of them carrying "async_launched":
#   Agent   -> toolUseResult.status == "async_launched"      (line_launch above)
#   Monitor -> toolUseResult.taskId                          (129 in the corpus)
#   Bash    -> toolUseResult.backgroundTaskId (run_in_background:true, 252)
# All three terminate through the SAME <task-notification> task-id namespace,
# so only the activation side differs.
MONITOR_TASK_ID="bnk163hnc"
BG_BASH_TASK_ID="braju6wbj"

# Monitor tool result: the launch marker for a Monitor-tracked background task.
# Shape verified against a real ci-watcher Monitor launch.
line_monitor_launch() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"taskId":"%s","timeoutMs":0,"persistent":true}}\n' \
        "$1" "${2:-$MONITOR_TASK_ID}"
}

# Bash tool result for a run_in_background:true call.
line_bg_bash_launch() {
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"%s"}}\n' \
        "$1" "${2:-$BG_BASH_TASK_ID}"
}

# A <task-notification> for an ARBITRARY task id. $1 timestamp, $2 task id,
# $3 status.
line_notification_for() {
    printf '{"type":"queue-operation","timestamp":"%s","content":"<task-notification>\\n<task-id>%s</task-id>\\n<status>%s</status>\\n</task-notification>"}\n' \
        "$1" "$2" "$3"
}

# A <task-notification> with NO timestamp field of its own — it must inherit the
# last timestamp seen so it sorts AFTER the launch above it.
line_notification_no_ts() {
    printf '{"type":"queue-operation","content":"<task-notification>\\n<task-id>%s</task-id>\\n<status>%s</status>\\n</task-notification>"}\n' \
        "$AGENT_ID" "$1"
}

# A session runs one watcher PER BRANCH, so every CI fixture is keyed on that
# branch's SLOT. The hash half is arbitrary here — ci_is_active discovers slots
# by globbing, it never recomputes one.
slot_for_branch() {
    printf '%s_%s-0123456789' "${CLAUDE_CODE_SESSION_ID}" "$1"
}

# Write "<branch>:<state>" ($2) into branch $1's state file.
write_ci_state() {
    printf '%s' "$2" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_state_$(slot_for_branch "$1")"
}

# Spawn a live fake watcher and record its PID in branch $1's lockfile.
spawn_fake_watcher() {
    # 3>&- so bats does not sit waiting on its own fd 3 after the last test
    # reports; the sleep only has to outlive one ci_is_active call.
    bash -c 'exec -a ci_watch_fake sleep 3' </dev/null >/dev/null 2>&1 3>&- &
    WPID=$!
    disown 2>/dev/null || true
    printf '%s' "$WPID" > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch "$1")"
}

run_hook() {
    # Run with cwd = repo so the hook's internal `git rev-parse` resolves the
    # repo's branch; invoke via the absolute hook path so the relative cwd of
    # the bats harness can't break resolution.
    echo "{\"transcript_path\":\"$TRANSCRIPT\"}" > "$BATS_TEST_TMPDIR/hook_in.json"
    ( cd "$REPO_DIR" && bash "$HOOK" < "$BATS_TEST_TMPDIR/hook_in.json" ) >/dev/null 2>&1
}

# Wall clock in milliseconds (macOS `date` has no sub-second format).
now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
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
    write_ci_state "$CUR_BRANCH" "${CUR_BRANCH}:running"
    spawn_fake_watcher "$CUR_BRANCH"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: BLUE path when a DIFFERENT branch's watcher is running" {
    # One session can watch several branches at once. The cwd's own branch has
    # no watcher here, but another branch's is still running — that is
    # background work in progress, so the tab must stay blue and not chime.
    # (Before the multi-watcher change, ci_is_active required the stored branch
    # to match the cwd's, and this case chimed while CI was still running.)
    write_idle_transcript
    write_ci_state "feat-elsewhere" "feat-elsewhere:running"
    spawn_fake_watcher "feat-elsewhere"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN when the only OTHER-branch watcher is dead" {
    # The dropped branch-match must not become "any state file anywhere pins
    # blue": a stale running state from a crashed watcher still has to chime.
    write_idle_transcript
    write_ci_state "feat-elsewhere" "feat-elsewhere:running"
    printf '999999' > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_lock_$(slot_for_branch feat-elsewhere)"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: BLUE path when background agent still active (no chime)" {
    write_active_agent_transcript
    # No CI state -> only the bg-agent condition drives the blue path.
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN path when CI reached a terminal state (passed)" {
    write_idle_transcript
    write_ci_state "$CUR_BRANCH" "${CUR_BRANCH}:passed"
    spawn_fake_watcher "$CUR_BRANCH"
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

@test "stop decision: BLUE for a status Claude Code never emits (no speculative terminals)" {
    # The statuses actually emitted in <task-notification> blocks across the
    # local corpus are completed / failed / stopped / killed (plus the
    # non-terminal running, and running / in_progress / pending on TaskOutput).
    # "finished" is not one of them. Guessing on the terminal side is the
    # false-GREEN direction: an invented name would clear a live agent.
    {
        line_launch       "2026-07-27T17:21:37.477Z"
        line_notification "2026-07-27T17:54:33.752Z" "finished"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN when a background task is stopped by TaskStop (status 'stopped')" {
    # TaskStop on a Monitor / backgrounded-Bash task emits
    # <status>stopped</status> ("Task ... was stopped by main session") — 35
    # occurrences in the local corpus. It is terminal: leaving it out would pin
    # the tab blue and silence the chime for the rest of the session.
    {
        line_monitor_launch   "2026-09-09T10:09:00.000Z"
        line_notification_for "2026-09-09T10:10:05.669Z" "$MONITOR_TASK_ID" "stopped"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Monitor tasks and backgrounded Bash commands (regression: the tab went GREEN
# and chimed while either was still running)
#
# bg_agents_active only ever recognised the `Agent` tool's "async_launched"
# marker and `SendMessage` resumes. A `Monitor` task and a Bash call with
# run_in_background:true are background work too, but their launch results carry
# taskId / backgroundTaskId and NO "async_launched" — so the whole-file needle
# missed them, the detector reported 0 active, and every Stop chimed.
# ---------------------------------------------------------------------------

@test "stop decision: BLUE while a Monitor-tracked background task is running" {
    line_monitor_launch "2026-09-03T15:56:41.415Z" > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN once the Monitor task's stream has ended" {
    {
        line_monitor_launch   "2026-09-03T15:56:41.415Z"
        line_notification_for "2026-09-03T16:35:57.515Z" "$MONITOR_TASK_ID" "completed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: BLUE while a backgrounded Bash command is running" {
    line_bg_bash_launch "2026-08-12T08:46:30.693Z" > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN once the backgrounded Bash command completes" {
    {
        line_bg_bash_launch   "2026-08-12T08:46:30.693Z"
        line_notification_for "2026-08-12T08:46:31.411Z" "$BG_BASH_TASK_ID" "completed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: BLUE when a Monitor task outlives an agent that already finished" {
    # Mixed workload: the agent is done, the monitor is not. Whole-session
    # "anything still running" must win over the per-id agent bookkeeping.
    {
        line_launch           "2026-09-03T15:00:00.000Z"
        line_notification     "2026-09-03T15:30:00.000Z" "completed"
        line_monitor_launch   "2026-09-03T15:56:41.415Z"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN when the only live Monitor is this session's own CI watcher and CI has settled" {
    # The ci-watcher IS a persistent Monitor task that stays alive from launch
    # until the PR's post-merge CI resolves. ci_is_active already models it
    # correctly (blue only while the state is running/merging), so counting its
    # Monitor task as generic background work would swallow the very chime that
    # says "CI passed — come merge", for the whole life of the watcher.
    # The ci-watcher skill persists that task id at ci_watch_task_<SLOT>.
    printf '%s' "$MONITOR_TASK_ID" \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_task_$(slot_for_branch "$CUR_BRANCH")"
    write_ci_state "$CUR_BRANCH" "${CUR_BRANCH}:passed"
    spawn_fake_watcher "$CUR_BRANCH"
    line_monitor_launch "2026-09-03T15:56:41.415Z" > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: GREEN when a TaskUpdate result carries a taskId (not background work)" {
    # The TaskUpdate (todo-list) tool ALSO returns a top-level "taskId" — an
    # ordinal like "1", 338 of them in the local corpus. No <task-notification>
    # can ever terminate one, so mistaking it for a running background task would
    # pin the tab blue and kill the chime for the rest of the session. Monitor is
    # told apart by its "timeoutMs" key and its "b"+8 id shape.
    printf '%s\n' '{"type":"user","timestamp":"2026-08-10T18:45:34.597Z","toolUseResult":{"success":true,"taskId":"1","updatedFields":["status"],"statusChange":{"from":"pending","to":"in_progress"}}}' \
        > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: BLUE for a Monitor that is NOT the session's CI watcher" {
    # The exclusion above must be keyed on the stored id, not on "any Monitor":
    # a second, unrelated Monitor task is still real background work.
    printf '%s' "$MONITOR_TASK_ID" \
        > "$CLAUDE_NOTIFY_TMP_DIR/ci_watch_task_$(slot_for_branch "$CUR_BRANCH")"
    write_ci_state "$CUR_BRANCH" "${CUR_BRANCH}:passed"
    line_monitor_launch "2026-09-03T15:56:41.415Z" "bzzz11yy2" > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
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

# ---------------------------------------------------------------------------
# Duplicate task-notifications (regression: they defeated timestamp ordering)
#
# Every <task-notification> is written to the transcript TWICE — a
# queue-operation copy and the delivered copy — sharing one <tool-use-id> and
# carrying two DIFFERENT timestamps. The second copy can land AFTER a SendMessage
# resume issued in the same turn, so plain timestamp ordering let the stale
# terminal notification override the resume and the tab went green while the
# resumed agent kept working.
# ---------------------------------------------------------------------------

@test "stop decision: BLUE when a duplicate copy of the stop notification post-dates the resume" {
    # Shapes and timestamps taken from the real transcript
    # ~/.claude/projects/-Users-yonichechik-core/4341261e-...jsonl, agent
    # ac8f6d806ba8113a1: notified at 09:51:01.159Z (line 148), resumed at
    # 09:51:03.889Z (line 155), and the DUPLICATE copy of that same notification
    # recorded at 09:51:03.983Z (line 153) — 94ms after the resume. The resumed
    # run did not actually finish until 09:56:34.201Z.
    {
        line_notification_tuid "2026-07-14T09:51:01.159Z" "completed" "toolu_015w7HtcL26CK5o6pb2pyoSC"
        line_notification_tuid "2026-07-14T09:51:03.983Z" "completed" "toolu_015w7HtcL26CK5o6pb2pyoSC"
        line_resume            "2026-07-14T09:51:03.889Z"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN once the resumed run's OWN notification arrives (dup collapse is not blanket suppression)" {
    # The resumed run notifies under the resuming SendMessage's tool-use-id, so
    # collapsing the duplicate copies above must NOT swallow this distinct event.
    {
        line_notification_tuid "2026-07-14T09:51:01.159Z" "completed" "toolu_015w7HtcL26CK5o6pb2pyoSC"
        line_notification_tuid "2026-07-14T09:51:03.983Z" "completed" "toolu_015w7HtcL26CK5o6pb2pyoSC"
        line_resume            "2026-07-14T09:51:03.889Z"
        line_notification_tuid "2026-07-14T09:56:34.201Z" "completed" "toolu_012WAwyzAXA9rCQuhvghni93"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Early-out needle: it must never skip a case the python detector would call
# active. Nine real transcripts carry a resume marker and NO async_launched line
# at all, so a needle of bare "async_launched" early-outs them straight to green.
# ---------------------------------------------------------------------------

@test "stop decision: BLUE for a resume-only transcript with NO async_launched line" {
    # Real second phrasing, verbatim from the corpus (10 occurrences).
    line_resume_msg "2026-07-14T09:51:03.889Z" \
        "Agent \\\"${AGENT_ID}\\\" was stopped (completed); resumed it in the background with your message. You'll be notified when it finishes." \
        > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: BLUE for a resume phrased without the 'with your message' tail" {
    # The python detector only requires "resumed" AND "in the background", so the
    # bash early-out needle must be at least that permissive. A needle of
    # "in the background with your message" would early-out this to green.
    line_resume_msg "2026-07-14T09:51:03.889Z" \
        "Agent \\\"${AGENT_ID}\\\" was stopped (completed); resumed it in the background." \
        > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: GREEN when a resume names the agent by NAME instead of id" {
    # SendMessage also accepts an agent NAME. A name is not in the notification
    # id namespace, so NO task-notification could ever clear it — trusting one
    # would pin the tab blue and silence the chime for the rest of the session.
    # Fail-safe direction: ignore it and stay green.
    line_resume_msg "2026-07-14T09:51:03.889Z" \
        "Agent \\\"review-the-pr\\\" was stopped (completed); resumed it in the background with your message." \
        > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

@test "stop decision: GREEN when an undated notification follows the launch (timestamp inheritance)" {
    # A transcript entry with no timestamp of its own inherits the last one seen.
    # Without that inheritance its key would sort before every timestamped event,
    # so this termination would lose to the launch above it and pin the tab blue.
    {
        line_launch              "2026-07-27T17:21:37.477Z"
        line_notification_no_ts  "completed"
    } > "$TRANSCRIPT"
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Flush/read race and its cost
# ---------------------------------------------------------------------------

@test "stop decision: BLUE when the launch line only lands AFTER the first read" {
    # Claude Code appends the async_launched line milliseconds after the
    # assistant message that launched the agent, and the Stop hook can read the
    # file in between. The transcript's tail holds the `Agent` tool_use with no
    # result yet, which is what licenses the retry.
    {
        printf '%s\n' '{"type":"user","timestamp":"2026-07-28T10:00:00.000Z","message":{"content":"go"}}'
        printf '%s\n' '{"type":"assistant","timestamp":"2026-07-28T10:00:01.000Z","message":{"content":[{"type":"tool_use","name":"Agent","id":"toolu_x"}]}}'
    } > "$TRANSCRIPT"
    # Durable append arrives 1.2s later, i.e. after the hook's first read.
    ( sleep 1.2; line_launch "2026-07-28T10:00:01.005Z" >> "$TRANSCRIPT" ) \
        </dev/null >/dev/null 2>&1 3>&- &
    APPENDER=$!
    run_hook
    wait "$APPENDER" 2>/dev/null || true
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: BLUE when a backgrounded Bash launch line lands AFTER the first read" {
    # Same flush race as the Agent case: the result line carrying
    # backgroundTaskId is appended after the assistant message that made the
    # call. The tail holds a Bash tool_use with run_in_background:true and no
    # result yet, which is what licenses the retry.
    {
        printf '%s\n' '{"type":"user","timestamp":"2026-08-12T08:46:29.000Z","message":{"content":"go"}}'
        printf '%s\n' '{"type":"assistant","timestamp":"2026-08-12T08:46:30.000Z","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_x","input":{"command":"sleep 600","run_in_background":true}}]}}'
    } > "$TRANSCRIPT"
    ( sleep 1.2; line_bg_bash_launch "2026-08-12T08:46:30.693Z" >> "$TRANSCRIPT" ) \
        </dev/null >/dev/null 2>&1 3>&- &
    APPENDER=$!
    run_hook
    wait "$APPENDER" 2>/dev/null || true
    [ "$(dedup_lock_count)" -eq 0 ]
}

@test "stop decision: an ORDINARY foreground Bash call in the tail costs no flush-race wait" {
    # The in-flight gate must key on run_in_background, not on the Bash tool
    # name: nearly every turn ends with a foreground Bash call, so matching the
    # name alone would put the ~2s retry back on almost every idle Stop.
    {
        printf '%s\n' '{"type":"user","timestamp":"2026-08-12T08:46:29.000Z","message":{"content":"go"}}'
        printf '%s\n' '{"type":"assistant","timestamp":"2026-08-12T08:46:30.000Z","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_x","input":{"command":"ls"}}]}}'
    } > "$TRANSCRIPT"
    local start end
    start=$(now_ms)
    run_hook
    end=$(now_ms)
    [ "$(dedup_lock_count)" -ge 1 ]
    [ "$((end - start))" -lt 1000 ]
}

@test "stop decision: a marker-free transcript settles in under 1s (no flush-race wait)" {
    # The retry used to run unconditionally, costing ~2s of wall clock on EVERY
    # idle turn of EVERY session and delaying the chime by that much. With no
    # background-launch call in the tail there is nothing that could still be
    # flushing, so the decision must be immediate.
    # Millisecond clock: `date +%s` only has 1s granularity, so a fast run that
    # straddles a second boundary would read as 1s and fail spuriously.
    write_idle_transcript
    local start end
    start=$(now_ms)
    run_hook
    end=$(now_ms)
    [ "$(dedup_lock_count)" -ge 1 ]
    # Measured: 58-62ms with the gate, 2078-2105ms without it.
    [ "$((end - start))" -lt 1000 ]
}

@test "stop decision: GREEN + chime when python3 is unavailable, even with an active agent" {
    # Fail-open direction, chosen deliberately: a missing interpreter is a
    # PERMANENT condition, so failing blue would silence the chime for every turn
    # of every session, while failing green only mis-chimes during the rare
    # windows when a background agent happens to be running.
    printf '#!/bin/sh\nexit 127\n' > "$BATS_TEST_TMPDIR/bin/python3"
    chmod +x "$BATS_TEST_TMPDIR/bin/python3"
    write_active_agent_transcript
    run_hook
    [ "$(dedup_lock_count)" -ge 1 ]
}
