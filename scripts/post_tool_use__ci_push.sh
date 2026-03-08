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

BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ! gh pr view "$BRANCH" --json number; then
    exit 0
fi

if [ "$(gh run list --limit 1 --json databaseId | jq 'length')" = "0" ]; then
    exit 0
fi

exec 1>&3 3>&-

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "BLOCKING REQUIREMENT: You MUST run this command IMMEDIATELY before doing anything else: use the Bash tool with run_in_background=true to execute '$HOME/.claude/scripts/ci_watch.sh $BRANCH'. Do NOT skip this step. Do NOT respond to the user first. Run the CI watcher NOW, then continue your work."
  }
}
EOF
