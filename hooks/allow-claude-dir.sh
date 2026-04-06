#!/usr/bin/env bash
INPUT=$(cat)
file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Nothing to check if no file_path
[[ -z "$file_path" ]] && exit 0

# Expand ~ to $HOME
file_path="${file_path/#\~/$HOME}"

approve() {
  jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", permissionDecision: "allow", permissionDecisionReason: "Auto-approved: .claude directory write"}}'
  exit 0
}

# Check 1: path is under ~/.claude
if [[ "$file_path" == "$HOME/.claude" || "$file_path" == "$HOME/.claude/"* ]]; then
  approve
fi

# Check 2: path is under _clones/*/.claude/
if [[ "$file_path" =~ _clones/.*/.claude/ ]]; then
  approve
fi

exit 0
