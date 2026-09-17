#!/bin/bash
#
# PreToolUse hook: single dispatcher entry point that runs BOTH
# pre_tool_use__base_dir_protect.sh's and pre_tool_use__permission_guard.sh's
# checks against the same tool-call JSON, instead of Claude Code spawning two
# separate hook processes that each independently read and re-parse the
# identical stdin for every Bash/Edit/Write/NotebookEdit call.
#
# `rtk hook claude` stays its own separate, untouched PreToolUse hook entry in
# settings.json — it is a third-party hook and is NOT folded in here.
#
# Each check still runs exactly as its standalone script does: `source`d into
# a subshell (not re-exec'd as a fresh `bash` process — cheaper, no
# interpreter re-init) with the captured stdin fed back in via a here-string,
# so every `exit` inside either script terminates only that subshell. Neither
# script's internal logic is touched by this file.
#
# Combination semantics replicate how Claude Code itself combines multiple
# PreToolUse hook results for the same tool call (see the hooks guide,
# "Combine results from multiple hooks"): the most restrictive
# permissionDecision wins, in the order deny > ask > allow (no output). Both
# checks always run — one deny never skips running the other, matching
# Claude Code's own documented "no short-circuit" behavior for sibling hooks.
#
# FAIL-CLOSED
# -----------
# "No output" is the contract for "no rule matched", which means allow. That
# made every internal failure indistinguishable from a clean pass: with
# _shell_command_guard.sh missing, a sub-check that should have denied produced
# nothing and the command was silently allowed. A sub-check is therefore now
# trusted only when it exits 0 AND writes nothing to stderr. Anything else —
# non-zero exit, a stray stderr line, an unparseable decision — is treated as
# ASK, so a broken guard prompts the human instead of waving the call through.
# ASK rather than DENY because a guard that cannot run is a guard with no
# evidence: the human, not the model, gets to decide.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT=$(cat)

INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARD_INTERNAL_ERROR: a PreToolUse guard failed to run to completion, so the dispatcher is failing closed. Confirm manually only if you know this command is safe, and repair the guard scripts."}}'

# Scratch files for each sub-check's stderr. A sub-check that writes to stderr
# hit something it did not expect, so its silence on stdout cannot be trusted.
ERR_BASE_DIR=$(mktemp -t predispatch_base.XXXXXX 2>/dev/null) || ERR_BASE_DIR=""
ERR_PERMISSION=$(mktemp -t predispatch_perm.XXXXXX 2>/dev/null) || ERR_PERMISSION=""
cleanup() { [ -n "$ERR_BASE_DIR" ] && rm -f "$ERR_BASE_DIR"; [ -n "$ERR_PERMISSION" ] && rm -f "$ERR_PERMISSION"; }
trap cleanup EXIT

if [ -z "$ERR_BASE_DIR" ] || [ -z "$ERR_PERMISSION" ]; then
    # Cannot even create a scratch file — no way to observe the sub-checks.
    printf '%s' "$INTERNAL_ERROR_JSON"
    exit 0
fi

out_base_dir=$( (source "$SCRIPT_DIR/pre_tool_use__base_dir_protect.sh") <<<"$INPUT" 2>"$ERR_BASE_DIR" )
rc_base_dir=$?
out_permission=$( (source "$SCRIPT_DIR/pre_tool_use__permission_guard.sh") <<<"$INPUT" 2>"$ERR_PERMISSION" )
rc_permission=$?

# A sub-check is healthy only when it exited 0 and stayed quiet on stderr.
_check_failed() { # <exit code> <stderr file>
    [ "$1" -ne 0 ] && return 0
    [ -s "$2" ] && return 0
    return 1
}

if _check_failed "$rc_base_dir" "$ERR_BASE_DIR" || _check_failed "$rc_permission" "$ERR_PERMISSION"; then
    printf '%s' "$INTERNAL_ERROR_JSON"
    exit 0
fi

# Rank a hook's raw JSON output (or empty, meaning "no opinion" / allow) by
# restrictiveness so the two results can be compared, and hand back the JSON to
# forward for that rank. Output that is present but carries no recognizable
# decision is a MALFORMED result, not an opinion: it ranks as ask and is
# replaced by the internal-error JSON, so a garbled guard never reads as allow
# and never forwards junk to the harness.
RANK=0
RANK_JSON=""
_rank_decision() { # <raw hook output>
    local out="$1" decision=""
    RANK=0
    RANK_JSON=""
    [ -n "$out" ] || return 0
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    case "$decision" in
        deny) RANK=3; RANK_JSON="$out" ;;
        ask) RANK=2; RANK_JSON="$out" ;;
        allow) RANK=0; RANK_JSON="" ;;
        *) RANK=2; RANK_JSON="$INTERNAL_ERROR_JSON" ;;
    esac
}

_rank_decision "$out_base_dir"
rank_base_dir=$RANK
json_base_dir=$RANK_JSON
_rank_decision "$out_permission"
rank_permission=$RANK
json_permission=$RANK_JSON

if [ "$rank_base_dir" -ge "$rank_permission" ] && [ "$rank_base_dir" -gt 0 ]; then
    printf '%s' "$json_base_dir"
elif [ "$rank_permission" -gt 0 ]; then
    printf '%s' "$json_permission"
fi

exit 0
