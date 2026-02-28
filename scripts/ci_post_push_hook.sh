#!/usr/bin/env bash
# PostToolUse hook: detects git push / gh pr create and tells Claude to start a background CI watcher.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

if [[ "$COMMAND" != *"git push"* ]] && [[ "$COMMAND" != *"gh pr create"* ]]; then
    exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ! gh pr view "$BRANCH" --json number 2>/dev/null; then
    exit 0
fi

if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "BLOCKING REQUIREMENT: You MUST run this command IMMEDIATELY before doing anything else: use the Bash tool with run_in_background=true to execute '$HOME/.claude/scripts/ci_watch.sh $BRANCH'. Do NOT skip this step. Do NOT respond to the user first. Run the CI watcher NOW, then continue your work."
  }
}
EOF
