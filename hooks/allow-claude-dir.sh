#!/usr/bin/env bash
INPUT=$(cat)

# Extract target path from tool input using multiple fallbacks
file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# Expand ~ to $HOME
[[ -n "$file_path" ]] && file_path="${file_path/#\~/$HOME}"

approve() {
  jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", permissionDecision: "allow", permissionDecisionReason: "Auto-approved: .claude directory access"}}'
  exit 0
}

# Check file_path/path based targets
if [[ -n "$file_path" ]]; then
  # Check 1: path is under ~/.claude
  if [[ "$file_path" == "$HOME/.claude" || "$file_path" == "$HOME/.claude/"* ]]; then
    approve
  fi

  # Check 2: path is under _clones/*/.claude/
  if [[ "$file_path" =~ _clones/.*/.claude/ ]]; then
    approve
  fi
fi

# Check Bash commands for .claude path references
command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ -n "$command" ]]; then
  if [[ "$command" == *"$HOME/.claude"* || "$command" == *'~/.claude'* ]]; then
    approve
  fi
  if [[ "$command" =~ _clones/.*/.claude ]]; then
    approve
  fi
fi

exit 0
