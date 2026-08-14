# Claude Code Config

Personal Claude Code configuration (hooks, commands, agents, settings).

## Installation

**Prerequisites:**

- Claude Code installed (creates `~/.claude` on first run).
- [`uv`](https://docs.astral.sh/uv/) — runs the Python scripts (`ci_watch.py`) and the setup cleanup step.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YoniChechik/claude-code-config/main/setup.sh)
```

This git-enables your existing `~/.claude` directory, removes the retired webhook MCP registration, and sets up the `cc` alias.

## What it does

- **Sound notifications:** Hooks that play sounds when Claude needs attention.
- **`cc` alias:** Launches Claude (`claude`).
