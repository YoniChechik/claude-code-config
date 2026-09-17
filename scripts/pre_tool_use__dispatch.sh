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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT=$(cat)

out_base_dir=$( (source "$SCRIPT_DIR/pre_tool_use__base_dir_protect.sh") <<<"$INPUT" )
out_permission=$( (source "$SCRIPT_DIR/pre_tool_use__permission_guard.sh") <<<"$INPUT" )

# Rank a hook's raw JSON output (or empty, meaning "no opinion" / allow) by
# restrictiveness so the two results can be compared. Unknown/missing decision
# text also ranks as allow — same as Claude Code treating no output as "no
# opinion, let the normal permission flow apply."
_decision_rank() {
    local out="$1" decision=""
    if [ -n "$out" ]; then
        decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    fi
    case "$decision" in
        deny) echo 3 ;;
        ask) echo 2 ;;
        *) echo 0 ;;
    esac
}

rank_base_dir=$(_decision_rank "$out_base_dir")
rank_permission=$(_decision_rank "$out_permission")

if [ "$rank_base_dir" -ge "$rank_permission" ] && [ "$rank_base_dir" -gt 0 ]; then
    printf '%s' "$out_base_dir"
elif [ "$rank_permission" -gt 0 ]; then
    printf '%s' "$out_permission"
fi

exit 0
