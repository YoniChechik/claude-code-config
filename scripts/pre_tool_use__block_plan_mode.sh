#!/usr/bin/env bash

set -euo pipefail

tool_name="$(jq -r '.tool_name // empty' 2>/dev/null || true)"

if [[ "$tool_name" == "EnterPlanMode" || "$tool_name" == "ExitPlanMode" ]]; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "Use the /plan skill instead of EnterPlanMode/ExitPlanMode. The /plan skill writes a persistent plan-<feature>.md file with research, task breakdown, and a Codex critique pass — built-in plan mode is ephemeral and forbidden by CLAUDE.md."
        }
    }'
fi

exit 0
