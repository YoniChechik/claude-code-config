#!/usr/bin/env bash
# PostToolUse hook: detects git push / gh pr create and tells Claude to start a background CI watcher.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

if [[ "$COMMAND" != *"git push"* ]] && [[ "$COMMAND" != *"gh pr create"* ]]; then
    exit 0
fi

# Silence all stdout/stderr to prevent intermediate commands (gh, git, jq) from
# polluting the hook's JSON output. Restore stdout only for the final JSON block.
exec 3>&1 1>/dev/null 2>/dev/null
restore_stdout() { exec 1>&3 3>&- 2>/dev/null; }
trap restore_stdout EXIT

BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ! gh pr view "$BRANCH" --json number; then
    exit 0
fi

if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    exit 0
fi

restore_stdout
trap - EXIT

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "REMINDER: If you haven't already, launch the persistent CI watcher with run_in_background=true: \$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH — it runs persistently and tracks all new pushes automatically, no need to relaunch."
  }
}
EOF
