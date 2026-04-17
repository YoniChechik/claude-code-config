#!/bin/bash

# Appends orchestration rules that should only apply to the main agent, not subagents.
# CLAUDE.md and rules/*.md are auto-loaded into all agents. This hook uses UserPromptSubmit
# (main agent only) to inject orchestration rules that subagents should not see.

# Reset iTerm2 tab to default — Claude is now processing
printf '\033]6;1;bg;*;default\a' > /dev/tty 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$SCRIPT_DIR/../CLAUDE_append_to_user_prompt_main_agent_only.md"
