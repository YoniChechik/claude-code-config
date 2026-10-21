#!/usr/bin/env bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"

@test "the suite runs with a temporary HOME, not the real one" {
    [ -n "$BATS_REAL_HOME" ]
    [ "$HOME" != "$BATS_REAL_HOME" ]
    [[ $HOME == "$BATS_SUITE_TMPDIR"/* ]]
}

@test "hook_log without CLAUDE_HOOK_LOG_DIR writes under the temporary HOME, never to the real log" {
    marker="isolation-check-${BATS_RUN_TMPDIR##*/}-$BATS_TEST_NUMBER"
    run env -u CLAUDE_HOOK_LOG_DIR bash -c 'source "$1"; hook_log "$2"' _ "$SCRIPTS/_hook_log.sh" "$marker"
    [ "$status" -eq 0 ]
    grep -qF "$marker" "$HOME/.claude/logs/hooks.log"
    run grep -qF "$marker" "$BATS_REAL_HOOK_LOGS/hooks.log"
    [ "$status" -ne 0 ]
}

@test "no test in this run wrote to the real hook log" {
    for f in "$BATS_REAL_HOOK_LOGS/hooks.log" "$BATS_REAL_HOOK_LOGS/hooks.log.1"; do
        [ -f "$f" ] || continue
        run grep -F "${BATS_RUN_TMPDIR##*/}" "$f"
        [ "$status" -ne 0 ]
    done
}
