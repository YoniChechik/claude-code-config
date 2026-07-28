#!/usr/bin/env bats
#
# Tab-colour STATE MACHINE tests, asserted on the raw OSC bytes the hooks write.
#
# The other suites check side effects (the dedup lockdir); these check the bytes,
# because the bug they pin is a MISSING transition rather than a wrong decision:
# green was painted correctly and then never repainted, so no lockdir or exit code
# differs — only the absence of a later escape sequence does.
#
# Two seams make that possible:
#   - CLAUDE_NOTIFY_TTY redirects every emitter to a FIFO we drain into a file. An
#     exported bash function cannot do this: the hooks source _notify.sh, which
#     redefines _resolve_target_tty in the child and would discard the override.
#   - the hooks are dispatched THROUGH settings.json, so a script that exists but
#     is not wired (or is wired to the wrong matcher) fails the test.
#
# The capture target is a FIFO, not a plain file: the emitters write with
# `printf ... > "$tty"`, which truncates a regular file on every write and would
# leave only the last one behind.

setup() {
    REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    SETTINGS="$REPO_DIR/settings.json"

    export CLAUDE_NOTIFY_TMP_DIR="$BATS_TEST_TMPDIR"
    export CLAUDE_CODE_SESSION_ID="tabstate"

    # Silent afplay shim so the green path never chimes during the suite.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/afplay"
    chmod +x "$BATS_TEST_TMPDIR/bin/afplay"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    FIFO="$BATS_TEST_TMPDIR/tty_fifo"
    CAPTURE="$BATS_TEST_TMPDIR/tty_capture"
    mkfifo "$FIFO"
    : > "$CAPTURE"
    export CLAUDE_NOTIFY_TTY="$FIFO"
    # 3>&- is load-bearing: bats waits for its internal fd 3 to be closed by every
    # descendant, so a reader that inherits it hangs the run after the last test.
    cat "$FIFO" > "$CAPTURE" </dev/null 2>/dev/null 3>&- &
    READER_PID=$!
    disown 2>/dev/null || true
    # Hold a writer open so the reader never sees EOF between separate writes.
    exec 9>"$FIFO"

    TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
    SNAP=0

    GREEN_SEQ='6;1;bg;green;brightness;255'
    BLUE_SEQ='6;1;bg;blue;brightness;255'
    RESET_SEQ='6;1;bg;*;default'
}

teardown() {
    exec 9>&- || true
    [ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null || true
}

# --- Capture helpers --------------------------------------------------------
# Record the capture offset. Truncating instead would leave a sparse hole of NUL
# bytes, because the reader keeps its own write offset.
mark() {
    settle
    SNAP=$(wc -c < "$CAPTURE" | tr -d ' ')
}

# Bounded 1s-interval poll (never a bare sleep) until the capture stops growing,
# so assertions see every byte the hooks wrote.
settle() {
    local prev=-1 cur i
    for i in 1 2 3 4 5; do
        cur=$(wc -c < "$CAPTURE" | tr -d ' ')
        [ "$cur" = "$prev" ] && return 0
        prev=$cur
        sleep 1
    done
}

# Bytes written since the last mark, escaped for assertion.
since_mark() {
    settle
    tail -c "+$((SNAP + 1))" "$CAPTURE" 2>/dev/null | cat -v
}

# Assertions must be functions, not `[[ ... ]]`: bash does not fire the ERR trap
# for the `[[` keyword, so bats swallows a failing non-final one.
assert_emitted() {
    local seq="$1" actual
    actual=$(since_mark)
    case "$actual" in (*"$seq"*) return 0 ;; esac
    printf 'expected sequence: %s\nactual bytes: %s\n' "$seq" "$actual" >&2
    return 1
}

refute_emitted() {
    local seq="$1" actual
    actual=$(since_mark)
    case "$actual" in (*"$seq"*)
        printf 'expected NOT to emit: %s\nactual bytes: %s\n' "$seq" "$actual" >&2
        return 1
    ;; esac
    return 0
}

# --- Hook dispatcher -------------------------------------------------------
# Runs every hook settings.json wires for <event> whose matcher matches <tool>,
# feeding it <payload> on stdin. Only this repo's own scripts are run;
# third-party entries cannot affect tab colour.
run_hooks() {
    local event="$1" tool="$2" payload="$3" cmd matcher
    # jq emits "*" for a group with no matcher: `read` strips LEADING IFS
    # whitespace and a TAB counts, so an empty first field would shift the
    # command into $matcher and silently dispatch nothing.
    while IFS=$'\t' read -r matcher cmd; do
        [ -n "$cmd" ] || continue
        case "$cmd" in *"/.claude/scripts/"*) ;; *) continue ;; esac
        if [ "$matcher" != "*" ] && [ -n "$tool" ]; then
            [[ "$tool" =~ ^($matcher)$ ]] || continue
        fi
        # cwd = repo so the hooks' internal `git rev-parse` resolves a branch.
        ( cd "$REPO_DIR" && printf '%s' "$payload" \
            | bash -c "${cmd//\$HOME/$HOME}" ) >/dev/null 2>&1
    done < <(jq -r --arg e "$event" '
        .hooks[$e][]? as $g
        | $g.hooks[]?
        | [($g.matcher // "*"), .command] | @tsv' "$SETTINGS")
}

payload() { jq -nc "$@"; }

# A transcript with no background-agent markers whose last entry is a FOREGROUND
# Agent call still awaiting its result — the shape the real session had.
write_foreground_agent_transcript() {
    printf '%s\n' '{"type":"assistant","timestamp":"2026-07-28T10:36:04.655Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"description":"docs"}}]}}' > "$TRANSCRIPT"
}

write_idle_transcript() {
    printf '%s\n' '{"type":"user","timestamp":"2026-07-28T10:00:00.000Z","message":{"content":"hi"}}' > "$TRANSCRIPT"
}

write_active_agent_transcript() {
    printf '%s\n' '{"type":"user","timestamp":"2026-07-28T10:00:00.000Z","toolUseResult":{"status":"async_launched","agentId":"a0123456789abcdef"}}' > "$TRANSCRIPT"
}

# The real destructive command from the reported session; the guard asks on it.
GCLOUD_CMD='gcloud dns record-sets delete api.app.sunsay.com. --type=A --zone=sunsay-com --project=production-490411'

@test "tab state: a permission ask paints GREEN while a foreground agent runs" {
    write_foreground_agent_transcript
    mark
    run_hooks PreToolUse Bash "$(payload --arg c "$GCLOUD_CMD" --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}')"
    assert_emitted "$GREEN_SEQ"
}

@test "tab state: GREEN is cleared once the asked-about tool completes" {
    write_foreground_agent_transcript
    run_hooks PreToolUse Bash "$(payload --arg c "$GCLOUD_CMD" --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}')"
    mark
    run_hooks PostToolUse Bash "$(payload --arg c "$GCLOUD_CMD" --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"ok"},transcript_path:$t}')"
    assert_emitted "$RESET_SEQ"
}

@test "tab state: nothing is emitted when no state was ever painted" {
    write_idle_transcript
    mark
    run_hooks PostToolUse Bash "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"ls"},transcript_path:$t}')"
    refute_emitted "$RESET_SEQ"
}

@test "tab state: a genuine idle Stop still paints GREEN" {
    write_idle_transcript
    mark
    run_hooks Stop "" "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$t}')"
    assert_emitted "$GREEN_SEQ"
}

@test "tab state: the deliberate notify-waiting ping survives its own tool call" {
    write_idle_transcript
    bash -c "source '$REPO_DIR/scripts/_notify.sh' && notify_user_attention"
    mark
    NOTIFY_CMD="bash -c 'source \$HOME/.claude/scripts/_notify.sh && notify_user_attention'"
    run_hooks PostToolUse Bash "$(payload --arg c "$NOTIFY_CMD" --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}')"
    refute_emitted "$RESET_SEQ"
}

@test "tab state: the BLUE background bar is not wiped by a background tool call" {
    write_active_agent_transcript
    run_hooks Stop "" "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$t}')"
    mark
    run_hooks PostToolUse Bash "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"ls"},transcript_path:$t}')"
    refute_emitted "$RESET_SEQ"
}

@test "tab state: Stop paints BLUE while a background agent is active" {
    write_active_agent_transcript
    mark
    run_hooks Stop "" "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$t}')"
    assert_emitted "$BLUE_SEQ"
}

@test "tab state: a tool that merely READS the notify code still clears GREEN" {
    write_idle_transcript
    run_hooks Stop "" "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$t}')"
    mark
    # The needle lives in the tool RESPONSE, not the input: only a genuine ping
    # (needle in tool_input) is allowed to keep the tab green.
    run_hooks PostToolUse Read "$(payload --arg t "$TRANSCRIPT" \
        '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/x/_notify.sh"},tool_response:{content:"notify_user_attention"},transcript_path:$t}')"
    assert_emitted "$RESET_SEQ"
}
