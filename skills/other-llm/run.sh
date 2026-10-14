#!/usr/bin/env bash
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/_state.sh"

usage() {
    echo "Usage: $0 <codex|claude> <cwd> <prompt-file> <run-dir>" >&2
    exit 2
}

(($# == 4)) || usage
RUNNER="$1"
CWD="$2"
PROMPT_FILE="$3"
RUN_DIR="$4"
[[ "$RUNNER" == codex || "$RUNNER" == claude ]] || usage
[[ -d "$CWD" ]] || {
    echo "Error: cwd $CWD is not a directory." >&2
    exit 2
}
[[ -s "$PROMPT_FILE" ]] || {
    echo "Error: prompt file $PROMPT_FILE is missing or empty." >&2
    exit 2
}
mkdir -p "$RUN_DIR" || exit 1

OUT="$RUN_DIR/out.md"
ERR="$RUN_DIR/stderr.log"
STALL_S="${OTHER_LLM_STALL_S:-30}"
POLL_S="${OTHER_LLM_POLL_S:-5}"
STDIN_STALL='Reading additional input from stdin'
PID=""
MODEL_ARGS=()
[[ -n "${OTHER_LLM_MODEL:-}" ]] && MODEL_ARGS=(-m "$OTHER_LLM_MODEL")

launch() {
    : >"$ERR"
    if [[ "$RUNNER" == codex ]]; then
        codex exec --sandbox danger-full-access -c approval_policy="never" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} -C "$CWD" -o "$OUT" "$(cat "$PROMPT_FILE")" </dev/null >>"$ERR" 2>&1 &
    else
        (cd "$CWD" && exec claude -p --no-session-persistence "$(cat "$PROMPT_FILE")" </dev/null >"$OUT" 2>>"$ERR") &
    fi
    PID=$!
    echo "$PID" >"$RUN_DIR/pid"
}

mtime() {
    state_stat "$1" || return 1
    printf '%s' "${REPLY##* }"
}

stalled() {
    [[ -s "$ERR" ]] || return 1
    tail -n 1 "$ERR" | grep -qF "$STDIN_STALL" || return 1
    (($(date +%s) - $(mtime "$ERR") > STALL_S))
}

RELAUNCHED=0
launch
while kill -0 "$PID" 2>/dev/null; do
    if stalled; then
        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
        if ((RELAUNCHED)); then
            echo 124 >"$RUN_DIR/exit"
            echo "STALLED twice on stdin. stderr=$ERR"
            exit 124
        fi
        RELAUNCHED=1
        echo "STALLED on stdin, relaunched once" >>"$RUN_DIR/events"
        launch
        continue
    fi
    sleep "$POLL_S"
done
wait "$PID"
RC=$?
echo "$RC" >"$RUN_DIR/exit"
echo "DONE exit=$RC out=$OUT stderr=$ERR relaunched=$RELAUNCHED"
exit "$RC"
