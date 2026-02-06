#!/bin/bash

# =============================================================================
# WHY THIS HOOK EXISTS (user_prompt_submit)
# =============================================================================
# CLAUDE.md and rules/*.md are automatically loaded by Claude Code into BOTH
# the main agent AND all subagents on every prompt. No hook needed for that.
#
# However, the orchestration rules (CLAUDE_append_to_user_prompt_main_agent_only.md) should
# ONLY apply to the main agent, NOT to subagents. The main agent is the
# orchestrator - it delegates work but doesn't write code itself. Subagents
# (coder, explorer, etc.) need full freedom to edit files, run code, etc.
#
# This hook appends orchestration rules via the UserPromptSubmit hook, which
# only fires for the main agent's conversation. Subagents never see this
# output, so they remain unrestricted to do their implementation work.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$SCRIPT_DIR/../CLAUDE_append_to_user_prompt_main_agent_only.md"
