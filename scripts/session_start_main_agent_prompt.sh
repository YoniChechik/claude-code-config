#!/usr/bin/env bash
# ============================================================================
# session_start_main_agent_prompt.sh
# ----------------------------------------------------------------------------
# Purpose:
#   SessionStart hook that injects the "orchestrator / main agent only"
#   guidance (CLAUDE_append_to_user_prompt_main_agent_only.md) as additional
#   context for the current session.
#
# Why:
#   SessionStart fires exactly once per session and ONLY for the top-level
#   session — it never fires for Task-tool-spawned subagents (those get their
#   own SubagentStart/SubagentStop events instead). That makes it the correct
#   native mechanism to deliver main-agent-only rules with zero risk of
#   leaking into subagent context, instead of relying on CLAUDE.md text
#   asking subagents to "skip this section" (which also wasted tokens by
#   loading into every subagent regardless).
#
# Mechanism:
#   Claude Code sends a JSON payload on stdin shaped like
#   {"source": "startup"|"resume"|"clear"|"compact"|"fork", ...}.
#   We don't need to branch on "source" — the guidance applies every time the
#   main agent starts or resumes. To inject context, this hook MUST run
#   synchronously (no "async": true in settings.json) and print a JSON object
#   on stdout following the SessionStart "hookSpecificOutput" schema.
# ============================================================================

# Strict mode:
#   -e : exit on any error
#   -u : error on unset variables (catches typos)
#   -o pipefail : a pipeline fails if any stage fails (not just the last)
set -euo pipefail

# ----------------------------------------------------------------------------
# Step 1: Drain stdin so Claude Code never blocks waiting for us to read the
#   hook payload. We don't need any field from it (see "Why" above).
# ----------------------------------------------------------------------------
cat >/dev/null

# ----------------------------------------------------------------------------
# Step 2: Locate the guidance file next to this script's repo root.
# ----------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guidance_file="$script_dir/../CLAUDE_append_to_user_prompt_main_agent_only.md"

if [[ ! -f "$guidance_file" ]]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 3: Emit the guidance as SessionStart "additionalContext".
#   Built with `jq -n --rawfile` (not printf/%s) so the file content's
#   quotes, backticks, and newlines are always escaped correctly into valid
#   JSON — this file grows without this script needing to change.
# ----------------------------------------------------------------------------
jq -n --rawfile guidance "$guidance_file" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $guidance
    }
}'
