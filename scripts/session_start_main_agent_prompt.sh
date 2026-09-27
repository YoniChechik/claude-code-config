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
#
#   The guidance file itself uses "@path" lines (matching CLAUDE.md's own
#   `@`-import convention, e.g. "@skills/new-feature/SKILL.md") to pull in
#   other files. Claude Code's native `@`-import only applies to memory files
#   it loads itself, not to a hook's stdout — so this script expands those
#   lines itself before emitting JSON, resolving each referenced path
#   relative to the repo root.
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
# Step 3: Expand "@path" reference lines in the guidance file.
#   Each line that is only "@<relative-path>" gets replaced by the full
#   content of that file, resolved relative to the repo root
#   ($script_dir/..). A missing referenced file leaves the line untouched
#   instead of failing the hook.
# ----------------------------------------------------------------------------
repo_root="$script_dir/.."
expanded=""
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^@(.+)$ ]]; then
        ref_path="$repo_root/${BASH_REMATCH[1]}"
        if [[ -f "$ref_path" ]]; then
            expanded+="$(cat "$ref_path")"$'\n'
            continue
        fi
    fi
    expanded+="$line"$'\n'
done <"$guidance_file"

# ----------------------------------------------------------------------------
# Step 4: Emit the expanded guidance as SessionStart "additionalContext".
#   Built with `jq -n --arg` (not --rawfile, since the content is now an
#   expanded string, not a file) so quotes, backticks, and newlines are
#   always escaped correctly into valid JSON.
# ----------------------------------------------------------------------------
jq -n --arg guidance "$expanded" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $guidance
    }
}'
