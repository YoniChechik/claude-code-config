#!/usr/bin/env bats
#
# Tests for the bash snippets embedded in skills/ci-watcher/SKILL.md.
#
# The skill is prose, but Claude runs these blocks verbatim. A snippet that is
# syntactically broken, or that reports a dead watcher as ALIVE, silently turns
# into "TaskStop on a stale id" or "two watchers on one session".
#
# Strategy:
#   - Each block is EXTRACTED from SKILL.md by a marker string, so what runs is
#     the shipped text — a snippet edited in the skill without updating the test
#     fails here.
#   - The only edit applied is `/tmp/` -> BATS_TEST_TMPDIR, so the tests never
#     read or write the real /tmp files of a live watcher.
#   - Liveness uses a REAL alive process (exec -a ci_watch_fake sleep) against a
#     guaranteed-dead PID, so the real ps/grep logic runs unmocked.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does
# not fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

SKILL_MD="${BATS_TEST_DIRNAME}/../skills/ci-watcher/SKILL.md"

setup() {
    export CLAUDE_CODE_SESSION_ID="testsess"
    LOCK="$BATS_TEST_TMPDIR/ci_watch_lock_${CLAUDE_CODE_SESSION_ID}"
    TASK="$BATS_TEST_TMPDIR/ci_watch_task_${CLAUDE_CODE_SESSION_ID}"
    SPAWNED_PIDS=()
}

teardown() {
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
}

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

# Extract the first ```bash fenced block of SKILL.md that contains $1, rewrite
# its /tmp/ paths into the per-test tmpdir, and write it to a runnable script.
# Echoes the script path.
extract_block() {
    local marker="$1"
    local out="$BATS_TEST_TMPDIR/block_$$.sh"
    awk -v marker="$marker" '
        /^```bash$/ { inblock = 1; buf = ""; next }
        /^```$/ {
            if (inblock && index(buf, marker) > 0) { printf "%s", buf; exit }
            inblock = 0; next
        }
        inblock { buf = buf $0 "\n" }
    ' "$SKILL_MD" | sed "s#/tmp/#${BATS_TEST_TMPDIR}/#g" > "$out"
    # A marker that no longer matches would silently produce an empty script
    # and make every assertion below pass vacuously.
    if [ ! -s "$out" ]; then
        printf 'no ```bash block in SKILL.md contains: %s\n' "$marker" >&2
        return 1
    fi
    printf '%s' "$out"
}

# Spawn a real, alive process whose argv contains "ci_watch" so the ps/grep
# check in the snippet passes against a genuine process. Echoes its PID.
# The sleep stays short: the append below happens inside the command
# substitution subshell, so teardown cannot reap it and bats waits for it.
spawn_fake_watcher() {
    spawn_named_process "ci_watch_fake"
}

# Same, for a live process whose argv does NOT mention ci_watch.
spawn_unrelated_process() {
    spawn_named_process "totally_unrelated"
}

spawn_named_process() {
    bash -c "exec -a $1 sleep 3" </dev/null >/dev/null 2>&1 3>&- &
    local pid=$!
    disown 2>/dev/null || true
    SPAWNED_PIDS+=("$pid")
    printf '%s' "$pid"
}

# ---------------------------------------------------------------------------
# Liveness check (stale task-id handling)
# ---------------------------------------------------------------------------

@test "liveness: ALIVE with the pid when the lockfile points at a live watcher" {
    local script pid
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_fake_watcher)"
    printf '%s' "$pid" > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "ALIVE $pid" ]
}

@test "liveness: DEAD when no lockfile exists" {
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"
    rm -f "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: DEAD when the lockfile is empty (crashed mid-write)" {
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"
    : > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: DEAD when the recorded pid is gone" {
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"
    printf '999999' > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: DEAD when the pid is alive but is not a ci_watch process" {
    # PID recycling: an unrelated process must never be reported as the watcher.
    # (Not $$ — the bats process argv holds this file's name, which itself
    # contains "ci_watch" and would match the grep.)
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"
    printf '%s' "$(spawn_unrelated_process)" > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: DEAD when the lockfile holds garbage instead of a pid" {
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"
    printf 'not-a-pid' > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

# ---------------------------------------------------------------------------
# step 0: stop subcommand
# ---------------------------------------------------------------------------

@test "stop: prints NONE when no watcher was ever launched in this session" {
    local script
    script="$(extract_block 'cannot stop ci watcher')"
    rm -f "$TASK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "NONE" ]
}

@test "stop: prints the stored task id when one exists" {
    local script
    script="$(extract_block 'cannot stop ci watcher')"
    printf 'task_abc123' > "$TASK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "task_abc123" ]
}

@test "stop: fails loudly when CLAUDE_CODE_SESSION_ID is unset" {
    # Without the guard the paths would collapse to /tmp/ci_watch_task_ and one
    # session could stop another session's watcher.
    local script
    script="$(extract_block 'cannot stop ci watcher')"

    run env -u CLAUDE_CODE_SESSION_ID bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "CLAUDE_CODE_SESSION_ID is unset" "$output"
}

# ---------------------------------------------------------------------------
# step 2: launch
# ---------------------------------------------------------------------------

@test "launch: reports session, cwd and NONE when there is no previous task id" {
    local script
    script="$(extract_block 'cannot launch ci watcher')"
    rm -f "$TASK"

    run bash "$script"
    [ "$status" -eq 0 ]
    assert_contains "SESSION=testsess" "$output"
    assert_contains "DIR=$(pwd)" "$output"
    assert_contains "NONE" "$output"
}

@test "launch: fails loudly when CLAUDE_CODE_SESSION_ID is unset" {
    local script
    script="$(extract_block 'cannot launch ci watcher')"

    run env -u CLAUDE_CODE_SESSION_ID bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "CLAUDE_CODE_SESSION_ID is unset" "$output"
}

@test "launch: surfaces a previous task id so it can be stopped first" {
    local script
    script="$(extract_block 'cannot launch ci watcher')"
    printf 'task_old' > "$TASK"

    run bash "$script"
    [ "$status" -eq 0 ]
    assert_contains "task_old" "$output"
}

# ---------------------------------------------------------------------------
# task-id persistence
# ---------------------------------------------------------------------------

@test "task-id write: lands atomically with no newline and no leftover .tmp" {
    local script
    script="$(extract_block '<TASK_ID>')"
    # The block ships a placeholder; substitute a realistic id to run it.
    sed -i.orig 's/<TASK_ID>/task_xyz789/' "$script"

    run bash "$script"
    [ "$status" -eq 0 ]

    run cat "$TASK"
    [ "$output" = "task_xyz789" ]
    # printf '%s' (not echo): a trailing newline would end up inside the id a
    # reader passes to TaskStop.
    run wc -c < "$TASK"
    [ "$(echo "$output" | tr -d ' ')" = "11" ]
    [ ! -e "${TASK}.tmp" ]
}

@test "task-id write: overwrites the id of a previous launch" {
    local script
    printf 'task_old' > "$TASK"
    script="$(extract_block '<TASK_ID>')"
    sed -i.orig 's/<TASK_ID>/task_new/' "$script"

    run bash "$script"
    [ "$status" -eq 0 ]
    run cat "$TASK"
    [ "$output" = "task_new" ]
}

# ---------------------------------------------------------------------------
# The skill must not resurrect the webhook launch path
# ---------------------------------------------------------------------------

@test "skill: launches ci_watch.py with the branch as its only argument" {
    run cat "$SKILL_MD"
    assert_contains 'uv run ~/.claude/scripts/ci_watch.py "$BRANCH"' "$output"
    # Port / session-token args, the webhook port tool, and the kill flag are
    # all gone.
    assert_not_contains '"$BRANCH" "$PORT"' "$output"
    assert_not_contains "get_port" "$output"
    assert_not_contains "ci_watch_kill_" "$output"
    assert_not_contains "run_in_background" "$output"
}
