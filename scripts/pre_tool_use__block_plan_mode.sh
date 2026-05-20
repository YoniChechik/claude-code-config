#!/usr/bin/env bash
# ============================================================================
# pre_tool_use__block_plan_mode.sh
# ----------------------------------------------------------------------------
# Purpose:
#   PreToolUse hook that blocks Claude Code's built-in plan-mode tools
#   (EnterPlanMode / ExitPlanMode) and redirects to the user's /plan skill.
#
# Why:
#   The user's global CLAUDE.md forbids EnterPlanMode/ExitPlanMode because the
#   built-in plan mode is ephemeral. The /plan skill writes a persistent
#   plan-<feature>.md artifact (with research + Codex critique). Models tend
#   to ignore the textual rule, so this hook enforces it programmatically.
#
# Mechanism:
#   Claude Code sends each PreToolUse hook a JSON object on stdin shaped like
#   {"tool_name": "...", "tool_input": {...}}.
#   To deny the tool call, we print a JSON object on stdout that follows the
#   PreToolUse "hookSpecificOutput" schema with permissionDecision="deny",
#   then exit 0. Claude Code reads that decision and surfaces the reason
#   string back to the model.
# ============================================================================

# Strict mode:
#   -e : exit on any error
#   -u : error on unset variables (catches typos)
#   -o pipefail : a pipeline fails if any stage fails (not just the last)
set -euo pipefail

# ----------------------------------------------------------------------------
# Step 1: Read the entire hook JSON payload from stdin into a variable.
#   We use `cat` rather than reading line-by-line because the payload is a
#   single JSON document and may technically contain newlines inside strings.
# ----------------------------------------------------------------------------
input_json="$(cat)"

# ----------------------------------------------------------------------------
# Step 2: Extract the tool name with jq.
#   `-r` prints the raw string (no surrounding quotes).
#   `// empty` makes jq emit nothing rather than the literal "null" if the
#   key is missing, so `tool_name` becomes an empty string in that case.
# ----------------------------------------------------------------------------
tool_name="$(printf '%s' "$input_json" | jq -r '.tool_name // empty')"

# ----------------------------------------------------------------------------
# Step 3: If this is one of the forbidden plan-mode tools, deny it.
#   The matcher in settings.json already filters to EnterPlanMode|ExitPlanMode,
#   so in practice we will only ever see those two names — but we check
#   defensively in case the hook is ever invoked without a matcher.
# ----------------------------------------------------------------------------
if [[ "$tool_name" == "EnterPlanMode" || "$tool_name" == "ExitPlanMode" ]]; then
  # Build the deny response as JSON with jq so any future edits to the reason
  # string can never break JSON quoting/escaping. The schema below is the
  # documented PreToolUse "hookSpecificOutput" envelope.
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use the /plan skill instead of EnterPlanMode/ExitPlanMode. The /plan skill writes a persistent plan-<feature>.md file with research, task breakdown, and a Codex critique pass — built-in plan mode is ephemeral and forbidden by CLAUDE.md."
    }
  }'
  # Exit 0: hook itself succeeded; the deny decision is communicated via the
  # JSON payload, not via exit code.
  exit 0
fi

# ----------------------------------------------------------------------------
# Step 4: Defense-in-depth fallthrough.
#   For any other tool name (shouldn't happen given the matcher), emit no
#   output and exit 0 — i.e. don't interfere with the tool call.
# ----------------------------------------------------------------------------
exit 0
