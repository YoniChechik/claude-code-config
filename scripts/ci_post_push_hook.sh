#!/usr/bin/env bash
# PostToolUse hook for Bash commands.
# Detects git push / gh pr create and tells Claude to start a background CI watcher.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Only proceed for git push or gh pr create
if [[ "$COMMAND" != *"git push"* ]] && [[ "$COMMAND" != *"gh pr create"* ]]; then
    exit 0
fi

# Fast check: skip CI watch if repo has no CI workflows configured
if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "You just pushed to branch '$BRANCH'. Run a background CI watch task now: use Bash with run_in_background=true to execute '$HOME/.claude/scripts/ci_watch.sh $BRANCH'. Continue your current work while it runs."
  }
}
EOF
