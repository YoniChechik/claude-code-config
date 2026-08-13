#!/usr/bin/env bats
#
# Tests for the webhook-MCP cleanup step in setup.sh.
#
# setup.sh removes the retired `mcpServers.webhook` entry from ~/.claude.json.
# A bug here is expensive in both directions: leaving the entry makes every
# session start error out on a missing channel/webhook.ts, and mangling the
# file (dropping sibling servers, truncating on malformed JSON) breaks every
# other MCP server the user has.
#
# Strategy:
#   - The python snippet is EXTRACTED from setup.sh at test time (the heredoc
#     body between `<<'PYTHON'` and the closing `PYTHON`), so the shipped code
#     is what runs — no copy that can drift.
#   - It runs through `uv run --no-project python`, exactly as setup.sh does.
#   - Every fixture lives in BATS_TEST_TMPDIR; the real ~/.claude.json is never
#     touched.
#
# Assertions go through helper functions, never a bare `[[ ... ]]`: bash does
# not fire the ERR trap for the `[[` keyword, so bats 1.13 SWALLOWS a failing
# non-final `[[ ... ]]` and reports the test as ok.

SETUP_SH="${BATS_TEST_DIRNAME}/../setup.sh"

setup() {
    SNIPPET="$BATS_TEST_TMPDIR/webhook_cleanup.py"
    # Pull the heredoc body out of setup.sh: start after the `<<'PYTHON'` line,
    # stop at the lone `PYTHON` terminator.
    awk "/<<'PYTHON'/{flag=1; next} /^PYTHON\$/{flag=0} flag" "$SETUP_SH" \
        > "$SNIPPET"
    TARGET="$BATS_TEST_TMPDIR/claude.json"
    BEFORE="$BATS_TEST_TMPDIR/claude.json.before"
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

# Write the fixture and keep a pristine copy for byte-identical comparisons.
write_target() {
    printf '%s' "$1" > "$TARGET"
    cp "$TARGET" "$BEFORE"
}

assert_target_unchanged() {
    if ! cmp -s "$TARGET" "$BEFORE"; then
        printf 'target was modified but should not have been:\n%s\n' \
            "$(cat "$TARGET")" >&2
        return 1
    fi
    return 0
}

run_cleanup() {
    uv run --no-project python "$SNIPPET" "$TARGET"
}

# ---------------------------------------------------------------------------
# The extraction itself
# ---------------------------------------------------------------------------

@test "extraction: the snippet pulled from setup.sh is the real cleanup code" {
    # Guards the awk above: an empty/garbled extraction would make every other
    # test in this file pass vacuously.
    run cat "$SNIPPET"
    [ "$status" -eq 0 ]
    assert_contains 'del servers["webhook"]' "$output"
    assert_contains 'json.dumps(config, indent=2)' "$output"
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

@test "removes mcpServers.webhook and keeps every sibling server" {
    write_target '{"mcpServers":{"webhook":{"command":"npx"},"linear":{"command":"x"}},"theme":"dark"}'

    run run_cleanup
    [ "$status" -eq 0 ]
    assert_contains "Removed mcpServers.webhook" "$output"

    run cat "$TARGET"
    assert_not_contains '"webhook"' "$output"
    assert_contains '"linear"' "$output"
    assert_contains '"theme": "dark"' "$output"
}

@test "removing the only server leaves an empty mcpServers, not a broken file" {
    write_target '{"mcpServers":{"webhook":{"command":"npx"}},"other":1}'

    run run_cleanup
    [ "$status" -eq 0 ]

    # Still valid JSON with the webhook key gone and siblings intact.
    run uv run --no-project python -c \
        "import json,sys;d=json.load(open(sys.argv[1]));print(d['mcpServers'],d['other'])" \
        "$TARGET"
    [ "$status" -eq 0 ]
    assert_contains "{} 1" "$output"
}

@test "rewritten file keeps 2-space indent and a trailing newline" {
    write_target '{"mcpServers":{"webhook":{"command":"npx"},"linear":{"command":"x"}}}'

    run run_cleanup
    [ "$status" -eq 0 ]

    # Last byte must be a newline (POSIX-clean file, no "\ No newline" diffs).
    run tail -c 1 "$TARGET"
    [ "$output" = "" ]
    run grep -c '^  "mcpServers": {$' "$TARGET"
    [ "$output" = "1" ]
}

@test "second run is a no-op (idempotent)" {
    write_target '{"mcpServers":{"webhook":{"command":"npx"},"linear":{"command":"x"}}}'
    run run_cleanup
    [ "$status" -eq 0 ]
    cp "$TARGET" "$BEFORE"

    run run_cleanup
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_target_unchanged
}

# ---------------------------------------------------------------------------
# No-op paths — setup.sh must never damage a config it does not understand
# ---------------------------------------------------------------------------

@test "no-op when ~/.claude.json does not exist" {
    rm -f "$TARGET"
    run run_cleanup
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$TARGET" ]
}

@test "no-op on malformed JSON — the file is left byte-identical" {
    write_target '{"mcpServers": {"webhook": '

    run run_cleanup
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_target_unchanged
}

@test "no-op when there is no mcpServers key" {
    write_target '{"theme":"dark"}'

    run run_cleanup
    [ "$status" -eq 0 ]
    assert_target_unchanged
}

@test "no-op when mcpServers has no webhook entry" {
    write_target '{"mcpServers":{"linear":{"command":"x"}}}'

    run run_cleanup
    [ "$status" -eq 0 ]
    assert_target_unchanged
}

@test "no-op when mcpServers is not an object" {
    write_target '{"mcpServers":["webhook"]}'

    run run_cleanup
    [ "$status" -eq 0 ]
    assert_target_unchanged
}

@test "no-op when the config root is not an object" {
    write_target '[1, 2, 3]'

    run run_cleanup
    [ "$status" -eq 0 ]
    assert_target_unchanged
}

# ---------------------------------------------------------------------------
# The rest of setup.sh must not resurrect the webhook launcher
# ---------------------------------------------------------------------------

@test "setup.sh installs a plain cc alias with no dev-channel flag" {
    run grep -c "^NEW_ALIAS=\"alias cc='claude'\"$" "$SETUP_SH"
    [ "$output" = "1" ]

    run cat "$SETUP_SH"
    assert_not_contains "dangerously-load-development-channels" "$output"
    assert_not_contains "npm install" "$output"
    assert_not_contains "CHANNEL_DIR" "$output"
}
