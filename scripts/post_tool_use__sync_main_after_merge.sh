#!/usr/bin/env bash
#
# PostToolUse:Bash hook — after a `gh pr merge` succeeds, immediately sync the
# PRIMARY checkout (never a worktree) to origin/main, instead of leaving it
# stale until the next SessionStart. The base-dir guard forbids agents from
# writing to the primary checkout directly, so without this a mid-session
# merge (including this hook's own PR) leaves the base repo's scripts/skills
# stale for the rest of the session, and for any other concurrent session.
#
# Deliberately permissive, unlike post_tool_use__ci_watch_trigger.sh: that
# hook's false positives launch a background watcher for the WRONG branch, a
# real correctness bug, so it parses the command's exact shape. Here an extra
# or missed sync is harmless — reset --hard origin/main is a no-op when
# nothing changed, and a missed one just waits for the next SessionStart —
# so this does not need that same exact-shape parsing.
#
# Output: none, ever. Syncing the primary checkout is invisible infrastructure
# the agent never needs to react to, so this hook emits no additionalContext
# and no systemMessage. Every step is best-effort and non-blocking: a broken
# sync must never surface as a tool error or slow down the real command.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# Cheap early exit before any subprocess: the settings.json matcher is a bare
# "Bash", so this runs on EVERY Bash tool call.
case "$input" in
    *"gh pr merge"*) ;;
    *) exit 0 ;;
esac

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Must actually be a `gh pr merge` invocation, not e.g. `gh pr merge --help`
# or a string that merely mentions it inside a commit message / PR body.
case "$cmd" in
    *"gh pr merge"*) ;;
    *) exit 0 ;;
esac
if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|=|$)'; then
    exit 0
fi

# Only a real success counts.
exit_code=$(printf '%s' "$input" | jq -r '.tool_response.exit_code // empty' 2>/dev/null)
[ "$exit_code" = "0" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0

# Resolve the PRIMARY checkout from the merge's own repo: the shared .git dir
# a worktree's git-dir sits under, or cwd itself when cwd IS the primary
# checkout. `--path-format=absolute` needs git 2.31+; fall back to resolving a
# relative answer against cwd on an older git.
common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
[ -n "$common_dir" ] || exit 0
case "$common_dir" in
    /*) ;;
    *) common_dir="$cwd/$common_dir" ;;
esac
primary_root=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd) || exit 0

# shellcheck source=./_git_sync.sh
source "${SCRIPT_DIR}/_git_sync.sh" 2>/dev/null || exit 0
_sync_primary_checkout_to_origin_main "$primary_root"

exit 0
