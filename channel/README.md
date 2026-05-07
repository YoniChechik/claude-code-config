# Webhook MCP Server

An MCP server that provides a channel for sending messages into a Claude session. Two interfaces: MCP tools (for Claude) and an HTTP server (for external scripts).

## MCP Tools (for Claude / LLM)

- **`notify`** — send a message to the channel directly
- **`get_port`** — returns the HTTP port for this session (pass to external scripts)

## HTTP Server (for external scripts)

- `POST http://127.0.0.1:<port>/` — send a message body as a channel notification (1 MB max)
- `GET http://127.0.0.1:<port>/health` — health check, returns `ok:<sessionToken>`
- Port is OS-assigned on startup; use `get_port` tool to discover it

## Multi-session

- Each Claude session starts its own webhook MCP server with its own HTTP port
- No shared state between sessions — no registry files, no port files
- Claude knows its port via `get_port` and passes it to any scripts it launches

## Usage Example

```bash
# Claude calls get_port → gets e.g. 8790:abc123
# Then launches the CI watcher with that port and session token:
uv run ~/.claude/scripts/ci_watch.py my-feature-branch 8790 abc123

# The watcher notifies via curl:
curl -s --max-time 5 -X POST http://127.0.0.1:8790/ --data-raw "CI failed on branch X"
```

## Setup

- Registered in `~/.claude.json` by `setup.sh`
- Requires `cc` alias (or `--dangerously-load-development-channels server:webhook`) to activate
