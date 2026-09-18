# Claude Code Config

Personal Claude Code configuration (hooks, commands, agents, settings).

## Installation

**Prerequisites:**

- Claude Code installed (creates `~/.claude` on first run).
- [`uv`](https://docs.astral.sh/uv/) — runs `ruff` for the post-edit lint hook and the setup cleanup step.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YoniChechik/claude-code-config/main/setup.sh)
```

This git-enables your existing `~/.claude` directory and removes the retired webhook MCP registration.

## What it does

- **Sound notifications:** Hooks that play sounds when Claude needs attention.
