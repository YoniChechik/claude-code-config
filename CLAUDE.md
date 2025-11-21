Be concise; avoid unnecessary detail.

## Full Feature Workflow (End-to-End)

**Development Loop (repeat until done):**
- Use `agent-Explore` codebase if needed
- Use `agent-coder` to implement next piece or fix simple bugs
- ONLY use `agent-debugger` to fix hard bugs that need runtime debugging (if any)
- Loop back to coder for next piece

**When you're done:**
- Use `agent-quality-enforcer` to fix code style/types
- Use `agent-reviewer` to comprehensive review

## Avoid Feature Drift

**On every new user prompt, check if we're drifting from the original task:**
- Is this request part of the current feature/task?
- If NOT, politely suggest: "This seems like a separate task. Should we add this to Linear for later and stay focused on [current task]?"
- Help user stay focused on completing current work before starting new things

## Miscellaneous

- **Package manager, running scripts and running tests**: `uv` - see .claude/knowledge/uv.md
- **Commit frequently** - You should commit your changes frequently as you make progress
- **Linear MCP**: Two Linear accounts available - prefer `linear-work` for album-maker repo, `linear-personal` for all else.
