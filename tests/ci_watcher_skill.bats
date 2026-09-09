#!/usr/bin/env bats
#
# Tests for the bash snippets embedded in skills/ci-watcher/SKILL.md.
#
# The skill is prose, but Claude runs these blocks verbatim. A snippet that is
# syntactically broken, or that reports a dead watcher as ALIVE, silently turns
# into "TaskStop on a stale id" or "two watchers on one slot".
#
# Strategy:
#   - Each block is EXTRACTED from SKILL.md by a marker string, so what runs is
#     the shipped text — a snippet edited in the skill without updating the test
#     fails here.
#   - The only edit applied is `/tmp/` -> BATS_TEST_TMPDIR, so the tests never
#     read or write the real /tmp files of a live watcher.
#   - Liveness uses a REAL alive process (exec -a ci_watch_fake sleep) against a
#     guaranteed-dead PID, so the real ps/grep logic runs unmocked.
#   - `gh` is stubbed on PATH: the slot block shells out to `gh repo view` for
#     the owner/repo half of the identity, and the suite must not hit the network.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does
# not fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

SKILL_MD="${BATS_TEST_DIRNAME}/../skills/ci-watcher/SKILL.md"
CI_WATCH_PY="${BATS_TEST_DIRNAME}/../skills/ci-watcher/ci_watch.py"

setup() {
    export CLAUDE_CODE_SESSION_ID="testsess"
    # The branch every fixture is keyed on, and the slot that follows from it.
    # The slot text itself is arbitrary here — only the "slot" tests below
    # assert how it is DERIVED; the rest just need one consistent key.
    BRANCH="feat-x"
    export SLOT="${CLAUDE_CODE_SESSION_ID}_feat-x-0123456789"
    LOCK="$BATS_TEST_TMPDIR/ci_watch_lock_${SLOT}"
    STATE="$BATS_TEST_TMPDIR/ci_watch_state_${SLOT}"
    TASK="$BATS_TEST_TMPDIR/ci_watch_task_${SLOT}"

    # `gh repo view --json nameWithOwner -q .nameWithOwner` -> "o/r", offline.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nprintf %%s "o/r"\n' > "$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # PIDs go to a FILE, not a shell array: every call site is
    # `$(spawn_fake_watcher)`, so an array append inside that command
    # substitution happens in a subshell and never reaches teardown.
    SPAWNED_PIDS_FILE="$BATS_TEST_TMPDIR/spawned_pids"
    : > "$SPAWNED_PIDS_FILE"
}

teardown() {
    while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$SPAWNED_PIDS_FILE"
    return 0
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
spawn_fake_watcher() {
    spawn_named_process "ci_watch_fake"
}

# Same, for a live process whose argv does NOT mention ci_watch.
spawn_unrelated_process() {
    spawn_named_process "totally_unrelated"
}

# The sleep must comfortably outlive the test: a decoy that has already exited
# turns "assert DEAD" into a test that passes for the wrong reason. teardown
# kills it, so the duration costs no wall clock. 3>&- is load-bearing — bats
# waits for its internal fd 3 to be closed by every descendant.
spawn_named_process() {
    bash -c "exec -a $1 sleep 300" </dev/null >/dev/null 2>&1 3>&- &
    local pid=$!
    disown 2>/dev/null || true
    printf '%s\n' "$pid" >> "$SPAWNED_PIDS_FILE"
    printf '%s' "$pid"
}

# Fail loudly if a decoy died before the check ran.
assert_process_alive() {
    if ! kill -0 "$1" 2>/dev/null; then
        printf 'helper process %s already exited before the check\n' "$1" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# The slot block: SESSION + branch + owner/repo -> SLOT
# ---------------------------------------------------------------------------

@test "slot: derives exactly what ci_watch.py's slot_for derives" {
    # The launcher and the watcher compute the slot INDEPENDENTLY, in two
    # languages. If they ever disagree the launcher writes its task id, log and
    # liveness checks against files no watcher will ever touch — with nothing
    # failing loudly. A non-ASCII branch is the case that separates a byte-mode
    # implementation from a codepoint-mode one.
    local script actual expected
    script="$(extract_block 'cannot key the ci watcher files')"

    run env BRANCH='féat/ü' bash "$script"
    [ "$status" -eq 0 ]
    actual="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"

    expected="$(cd "${BATS_TEST_DIRNAME}/.." && uv run --quiet --with requests \
        python -c '
import sys
sys.path.insert(0, "skills/ci-watcher")
import ci_watch
print(ci_watch.slot_for("testsess", "o", "r", "féat/ü"))
')"
    [ -n "$expected" ]
    [ "$actual" = "$expected" ]
}

@test "slot: two branches of one session get different slots" {
    local script slot_a slot_b
    script="$(extract_block 'cannot key the ci watcher files')"

    run env BRANCH='feat/a' bash "$script"
    slot_a="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"
    run env BRANCH='feat/b' bash "$script"
    slot_b="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"

    [ -n "$slot_a" ]
    [ "$slot_a" != "$slot_b" ]
}

@test "slot: a slug collision is separated by the identity hash" {
    # `feat/a` and `feat_a` sanitize to the same readable slug. Only the hash
    # keeps their slots apart — which is the entire reason the hash is there.
    local script slot_a slot_b
    script="$(extract_block 'cannot key the ci watcher files')"

    run env BRANCH='feat/a' bash "$script"
    slot_a="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"
    run env BRANCH='feat_a' bash "$script"
    slot_b="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"

    [ "$slot_a" != "$slot_b" ]
}

@test "slot: the same branch in two repos gets different slots" {
    # One session can `cd` between worktrees of different repos, and two repos
    # can both have a branch called `main`.
    local script slot_a slot_b
    script="$(extract_block 'cannot key the ci watcher files')"

    run env BRANCH='main' bash "$script"
    slot_a="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"
    printf '#!/bin/sh\nprintf %%s "o/other-repo"\n' > "$BATS_TEST_TMPDIR/bin/gh"
    run env BRANCH='main' bash "$script"
    slot_b="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"

    [ "$slot_a" != "$slot_b" ]
}

@test "slot: reports session, cwd and NONE when there is no previous task id" {
    local script expected_dir
    script="$(extract_block 'cannot key the ci watcher files')"

    # Run from a DIFFERENT directory than the test's own cwd: comparing the
    # snippet's `pwd` against the test's `pwd` would be true by construction.
    expected_dir="$(cd "$BATS_TEST_TMPDIR" && pwd)"
    cd "$BATS_TEST_TMPDIR"

    run env BRANCH='feat-x' bash "$script"
    [ "$status" -eq 0 ]
    assert_contains "SESSION=testsess" "$output"
    assert_contains "DIR=$expected_dir" "$output"
    assert_contains "NONE" "$output"
}

@test "slot: surfaces the task id of THIS branch's previous launch" {
    local script slot
    script="$(extract_block 'cannot key the ci watcher files')"
    run env BRANCH='feat-x' bash "$script"
    slot="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"
    printf 'task_old' > "$BATS_TEST_TMPDIR/ci_watch_task_${slot}"

    run env BRANCH='feat-x' bash "$script"
    [ "$status" -eq 0 ]
    assert_contains "task_old" "$output"
}

@test "slot: another branch's task id is NOT surfaced" {
    # The whole point of the per-branch slot: relaunching feat-x must not pick
    # up (and then TaskStop) the watcher that is running for feat-y.
    local script slot_y
    script="$(extract_block 'cannot key the ci watcher files')"
    run env BRANCH='feat-y' bash "$script"
    slot_y="$(printf '%s\n' "$output" | sed -n 's/^SLOT=//p')"
    printf 'task_other_branch' > "$BATS_TEST_TMPDIR/ci_watch_task_${slot_y}"

    run env BRANCH='feat-x' bash "$script"
    [ "$status" -eq 0 ]
    assert_not_contains "task_other_branch" "$output"
    assert_contains "NONE" "$output"
}

@test "slot: fails loudly when CLAUDE_CODE_SESSION_ID is unset" {
    # Without the guard every path collapses to /tmp/ci_watch_*_ and one session
    # would read (or stop) another session's watcher.
    local script
    script="$(extract_block 'cannot key the ci watcher files')"

    run env -u CLAUDE_CODE_SESSION_ID BRANCH='feat-x' bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "CLAUDE_CODE_SESSION_ID is unset" "$output"
}

@test "slot: fails loudly when no branch can be resolved" {
    # `git branch --show-current` prints nothing on a detached HEAD. Continuing
    # would key every file on an empty branch slug.
    local script
    script="$(extract_block 'cannot key the ci watcher files')"
    # A directory that is not a git repo, so the fallback resolves to nothing.
    mkdir -p "$BATS_TEST_TMPDIR/notarepo"
    cd "$BATS_TEST_TMPDIR/notarepo"

    run env -u BRANCH bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "no branch resolved" "$output"
}

# ---------------------------------------------------------------------------
# Liveness check (stale task-id handling)
# ---------------------------------------------------------------------------

@test "liveness: ALIVE with the pid when the lockfile points at a live watcher" {
    local script pid
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_fake_watcher)"
    assert_process_alive "$pid"
    printf '%s' "$pid" > "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "ALIVE $pid" ]
}

@test "liveness: MUTE when the watcher is alive but its notifications are lost" {
    # ci_watch.py appends ":monitor-detached@<epoch>" after a failed stdout
    # write. Reporting that as plain ALIVE hides a watcher that will never
    # report another CI result.
    local script pid
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_fake_watcher)"
    assert_process_alive "$pid"
    printf '%s' "$pid" > "$LOCK"
    printf '%s' 'feat-x:running:monitor-detached@1757000000' > "$STATE"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "MUTE $pid" ]
}

@test "liveness: ALIVE when the state file carries no detached marker" {
    local script pid
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_fake_watcher)"
    assert_process_alive "$pid"
    printf '%s' "$pid" > "$LOCK"
    printf '%s' 'feat-x:running' > "$STATE"

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
    local script pid
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_unrelated_process)"
    printf '%s' "$pid" > "$LOCK"

    # The whole point of this test is the `| grep -q ci_watch` guard. A decoy
    # that already exited would print DEAD for the wrong reason and keep passing
    # even if the grep were deleted from SKILL.md.
    assert_process_alive "$pid"
    run ps -p "$pid" -o args=
    assert_not_contains "ci_watch" "$output"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: reads only its OWN slot's lockfile" {
    # A live watcher on ANOTHER branch must not make this branch's dead watcher
    # look alive — that would suppress the relaunch that step 2 owes the user.
    local script pid other_slot
    script="$(extract_block 'ps -p "$PID" -o args=')"
    pid="$(spawn_fake_watcher)"
    assert_process_alive "$pid"
    other_slot="${CLAUDE_CODE_SESSION_ID}_feat-y-9876543210"
    printf '%s' "$pid" > "$BATS_TEST_TMPDIR/ci_watch_lock_${other_slot}"
    rm -f "$LOCK"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "DEAD" ]
}

@test "liveness: fails loudly when SLOT is unset" {
    # Without the guard the path collapses to /tmp/ci_watch_lock_ and the check
    # reports some other watcher's state as this branch's.
    local script
    script="$(extract_block 'ps -p "$PID" -o args=')"

    run env -u SLOT bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "SLOT is unset" "$output"
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
# step 0: stop-all discovery
# ---------------------------------------------------------------------------

@test "stop-all: prints nothing when the session has no watchers" {
    local script
    script="$(extract_block 'cannot enumerate ci watchers')"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stop-all: finds a watcher through its task-id file" {
    local script
    script="$(extract_block 'cannot enumerate ci watchers')"
    printf 'task_a' > "$BATS_TEST_TMPDIR/ci_watch_task_${SLOT}"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "$SLOT" ]
}

@test "stop-all: finds a watcher whose task-id file is missing, via lock or state" {
    # The task-id file can be reaped from /tmp, or never written at all if the
    # session died between Monitor returning and the id being persisted. A
    # task-id-only enumeration would leave that watcher running forever.
    local script slot_lock slot_state
    script="$(extract_block 'cannot enumerate ci watchers')"
    slot_lock="${CLAUDE_CODE_SESSION_ID}_feat-lock-1111111111"
    slot_state="${CLAUDE_CODE_SESSION_ID}_feat-state-2222222222"
    printf '4242' > "$BATS_TEST_TMPDIR/ci_watch_lock_${slot_lock}"
    printf 'feat-state:running' > "$BATS_TEST_TMPDIR/ci_watch_state_${slot_state}"

    run bash "$script"
    [ "$status" -eq 0 ]
    assert_contains "$slot_lock" "$output"
    assert_contains "$slot_state" "$output"
}

@test "stop-all: reports each slot exactly once across all three sources" {
    local script line_count
    script="$(extract_block 'cannot enumerate ci watchers')"
    printf 'task_a' > "$BATS_TEST_TMPDIR/ci_watch_task_${SLOT}"
    printf '4242' > "$BATS_TEST_TMPDIR/ci_watch_lock_${SLOT}"
    printf 'feat-x:running' > "$BATS_TEST_TMPDIR/ci_watch_state_${SLOT}"

    run bash "$script"
    [ "$status" -eq 0 ]
    line_count="$(printf '%s\n' "$output" | grep -c .)"
    [ "$line_count" -eq 1 ]
    [ "$output" = "$SLOT" ]
}

@test "stop-all: ignores another session's watchers" {
    local script
    script="$(extract_block 'cannot enumerate ci watchers')"
    printf 'task_other' > "$BATS_TEST_TMPDIR/ci_watch_task_othersess_feat-z-3333333333"

    run bash "$script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stop-all: fails loudly when CLAUDE_CODE_SESSION_ID is unset" {
    # Without the guard the glob widens to every session's files and stop-all
    # would kill watchers belonging to other terminals.
    local script
    script="$(extract_block 'cannot enumerate ci watchers')"

    run env -u CLAUDE_CODE_SESSION_ID bash "$script"
    [ "$status" -eq 1 ]
    assert_contains "CLAUDE_CODE_SESSION_ID is unset" "$output"
}

# ---------------------------------------------------------------------------
# task-id persistence
# ---------------------------------------------------------------------------

@test "task-id write: lands atomically with no newline and no leftover temp file" {
    local script leftovers
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
    # mktemp names are unpredictable, so assert on the shape instead of one path.
    leftovers="$(ls "$BATS_TEST_TMPDIR" | grep -c "^ci_watch_task_${SLOT}\." || true)"
    [ "$leftovers" -eq 0 ]
}

@test "task-id write: overwrites the id of a previous launch on the same slot" {
    local script
    printf 'task_old' > "$TASK"
    script="$(extract_block '<TASK_ID>')"
    sed -i.orig 's/<TASK_ID>/task_new/' "$script"

    run bash "$script"
    [ "$status" -eq 0 ]
    run cat "$TASK"
    [ "$output" = "task_new" ]
}

@test "task-id write: leaves another branch's task id untouched" {
    local script other_slot
    other_slot="${CLAUDE_CODE_SESSION_ID}_feat-y-9876543210"
    printf 'task_other' > "$BATS_TEST_TMPDIR/ci_watch_task_${other_slot}"
    script="$(extract_block '<TASK_ID>')"
    sed -i.orig 's/<TASK_ID>/task_new/' "$script"

    run bash "$script"
    [ "$status" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/ci_watch_task_${other_slot}"
    [ "$output" = "task_other" ]
}

@test "task-id write: uses a unique temp name, not a fixed .tmp suffix" {
    # Two near-simultaneous launches for one slot would otherwise write and
    # rename the very same "<file>.tmp" path, and one could publish the other's
    # half-written id.
    run cat "$SKILL_MD"
    assert_contains 'mktemp "${TASK_FILE}.XXXXXX"' "$output"
    assert_not_contains 'ci_watch_task_${CLAUDE_CODE_SESSION_ID}.tmp' "$output"
}

# ---------------------------------------------------------------------------
# The skill must not resurrect the webhook launch path
# ---------------------------------------------------------------------------

@test "skill: launches ci_watch.py with the branch as its only argument" {
    run cat "$SKILL_MD"
    assert_contains "uv run ~/.claude/skills/ci-watcher/ci_watch.py '<BRANCH>'" "$output"
    # Port / session-token args, the webhook port tool, and the kill flag are
    # all gone.
    assert_not_contains '"$BRANCH" "$PORT"' "$output"
    assert_not_contains "get_port" "$output"
    assert_not_contains "ci_watch_kill_" "$output"
    assert_not_contains "run_in_background" "$output"
}

@test "skill: every value interpolated into the Monitor command is single-quoted" {
    # Double quotes do NOT stop $(...), backticks or $VAR. A branch name may
    # legally contain all three, and the command string is run by a shell, so
    # double-quoting the branch is a live command-injection path.
    run cat "$SKILL_MD"
    assert_contains "cd '<DIR>'" "$output"
    assert_contains "CLAUDE_CODE_SESSION_ID='<SESSION>'" "$output"
    assert_contains "ci_watch.py '<BRANCH>'" "$output"
    assert_not_contains 'cd "$DIR"' "$output"
    assert_not_contains 'CLAUDE_CODE_SESSION_ID="$SESSION"' "$output"
    assert_not_contains 'ci_watch.py "$BRANCH"' "$output"
}

@test "skill: the Monitor command execs, is persistent, and redirects stderr only" {
    run cat "$SKILL_MD"
    # Without exec, TaskStop kills a parent shell and orphans the watcher.
    assert_contains "&& exec env CLAUDE_CODE_SESSION_ID=" "$output"
    assert_contains '`persistent`: `true`' "$output"
    # The log is keyed on the per-branch SLOT: two watchers of one session must
    # not append their diagnostics to a single shared log file.
    assert_contains "2>>'/tmp/ci_watch_<SLOT>.log'" "$output"
    assert_not_contains "2>>'/tmp/ci_watch_<SESSION>.log'" "$output"
    # stdout IS the notification stream. Redirecting it (&>> or 1>>) would make
    # every notification vanish with no test failing.
    assert_not_contains '&>>' "$output"
    assert_not_contains '1>>' "$output"
}

@test "skill: no file path is keyed on the bare session id any more" {
    # The old single-slot scheme is REPLACED, not kept alongside: a leftover
    # /tmp/ci_watch_state_${CLAUDE_CODE_SESSION_ID} path would read a file no
    # watcher writes.
    run cat "$SKILL_MD"
    assert_not_contains 'ci_watch_state_${CLAUDE_CODE_SESSION_ID}"' "$output"
    assert_not_contains 'ci_watch_lock_${CLAUDE_CODE_SESSION_ID}"' "$output"
    assert_not_contains 'ci_watch_task_${CLAUDE_CODE_SESSION_ID}"' "$output"
    assert_not_contains 'ci_watch_pr_${CLAUDE_CODE_SESSION_ID}"' "$output"
}

@test "skill: ci_watch.py exposes the slot helpers the skill mirrors" {
    # The skill's inline bash reimplements slot_for. If the python side ever
    # renames or drops these, the two halves silently drift apart.
    run cat "$CI_WATCH_PY"
    assert_contains "def sanitize_branch(" "$output"
    assert_contains "def slot_for(" "$output"
    assert_contains "def append_finished_pr(" "$output"
}
