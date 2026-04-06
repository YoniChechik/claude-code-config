#!/usr/bin/env bash
#
# allow-claude-dir.sh — PreToolUse hook for Claude Code
#
# PURPOSE:
#   Auto-approve file operations targeting the ~/.claude directory (and its
#   clones). Without this hook, Claude Code would prompt the user for permission
#   every time it tries to read/write files inside ~/.claude. This script
#   inspects the incoming PermissionRequest and, if the target lives under
#   ~/.claude, emits an "allow" decision so the operation proceeds silently.
#
# HOW IT WORKS:
#   Claude Code invokes PreToolUse hooks by piping a JSON PermissionRequest to
#   stdin. The hook can respond with an allow/deny decision, or exit silently
#   (exit 0 with no JSON) to express "no opinion" and let Claude Code fall
#   through to its default permission logic.
#

# Read the full PermissionRequest JSON from stdin.
# Claude Code passes the hook payload via stdin (not as CLI args), so we
# consume it all at once into a variable for repeated jq queries below.
INPUT=$(cat)

# Extract the target file path from the tool input.
# Different tools use different field names: file-based tools (Read, Write, Edit)
# use "file_path", while some others (e.g. Glob) use "path". We try both with
# jq's // (alternative operator) so we catch either variant.
file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# Expand a leading ~ to the real $HOME path.
# Bash does NOT expand ~ inside variable comparisons (e.g. [[ "$var" == "~/"* ]]
# always fails), so we must do the substitution ourselves before matching.
[[ -n "$file_path" ]] && file_path="${file_path/#\~/$HOME}"

# Helper: emit a JSON "allow" decision and exit immediately.
# The JSON structure is what Claude Code expects from a PreToolUse hook:
#   - hookEventName:            must match the hook event type ("PermissionRequest")
#   - permissionDecision:       "allow" grants the operation without prompting the user
#   - permissionDecisionReason: human-readable explanation shown in debug/audit logs
approve() {
  jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", permissionDecision: "allow", permissionDecisionReason: "Auto-approved: .claude directory access"}}'
  exit 0
}

# --- Check file_path / path based targets ---
if [[ -n "$file_path" ]]; then
  # Allow if the path is exactly ~/.claude or anything nested under it.
  if [[ "$file_path" == "$HOME/.claude" || "$file_path" == "$HOME/.claude/"* ]]; then
    approve
  fi

  # Allow if the path is inside a feature clone's .claude directory
  # (e.g. /some/repo/_clones/feature-x/.claude/settings.json).
  if [[ "$file_path" =~ _clones/.*/.claude/ ]]; then
    approve
  fi
fi

# --- Check Bash tool commands ---
# The Bash tool doesn't set file_path/path; it puts the shell command string in
# "command". We need a separate check to catch things like:
#   cat ~/.claude/settings.json
#   cd /Users/me/.claude && git status
command=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ -n "$command" ]]; then
  # Match commands that reference ~/.claude via the expanded $HOME or literal ~.
  if [[ "$command" == *"$HOME/.claude"* || "$command" == *'~/.claude'* ]]; then
    approve
  fi
  # Match commands referencing a clone's .claude directory.
  if [[ "$command" =~ _clones/.*/.claude ]]; then
    approve
  fi
fi

# Exit 0 without printing any JSON.
# This signals "no opinion" to Claude Code — the hook neither allows nor denies
# the operation, so Claude Code falls through to its normal permission handling
# (which will prompt the user if needed).
exit 0
