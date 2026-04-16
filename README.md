# Claude Code Config

Personal Claude Code configuration (hooks, commands, agents, settings).

## Installation

**Prerequisites:** Node.js 18+, Claude Code installed (creates `~/.claude` on first run).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YoniChechik/claude-code-config/main/setup.sh)
```

This git-enables your existing `~/.claude` directory, installs dependencies, configures the MCP server, and sets up the `cc` alias.

## What it does

- **Webhook channel:** MCP server for receiving messages from external processes (e.g., CI watcher). Registered directly in `~/.claude.json` by `setup.sh` (no separate `.mcp.json` needed).
- **Sound notifications:** Hooks that play sounds when Claude needs attention.
- **`cc` alias:** Launches Claude with the webhook channel enabled (`claude --dangerously-load-development-channels server:webhook`).
