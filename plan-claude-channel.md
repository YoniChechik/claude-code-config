# Feature: Claude Channel Webhook

## TLDR

Build a local MCP channel server (`channel/webhook.ts`) that listens on `localhost:8788`, receives HTTP POST notifications (e.g. from CI), and pushes them into Claude Code via the `notifications/claude/channel` protocol. Also wire up setup tooling: `package.json`, `.mcp.json`, `setup.sh`, and an e2e test script.

## Research and References

### Channels API Contract (from https://code.claude.com/docs/en/channels-reference.md)

- MCP server using `@modelcontextprotocol/sdk`, connected over **stdio** (Claude Code spawns it as subprocess)
- Must declare `capabilities.experimental['claude/channel']: {}` to register as a channel
- Push events via: `mcp.notification({ method: 'notifications/claude/channel', params: { content: string, meta?: Record<string, string> } })`
- `meta` keys become XML attributes on the `<channel>` tag Claude receives; keys must be `[a-zA-Z0-9_]` only (hyphens silently dropped)
- Launch flag required during research preview: `claude --dangerously-load-development-channels server:webhook`
- The `.mcp.json` entry for a bare server (no plugin wrapper): `{ "mcpServers": { "webhook": { "command": "npx", "args": ["tsx", "./webhook.ts"] } } }`
- Runtime: Bun, Node, or Deno all work. We use **Node + tsx** (not Bun) since tsx is listed as a dep and avoids an extra runtime install.

### Existing repo context

- Repo is `~/.claude` config, cloned at `/Users/yonichechik/.claude/_clones/claude-channel`
- `~/.zshrc` line 106: `alias cc="claude"` — needs updating to pass `--dangerously-load-development-channels server:webhook`
- `~/.bashrc` may or may not have the alias (grep returned exit 2, meaning file doesn't exist or alias absent)
- `settings.json` uses hooks for PostToolUse, PreToolUse, SessionStart, Stop, Notification — no channel config yet
- `skills/ci/SKILL.md`: CI watcher script runs `ci_watch_persistent.sh` in background — this is the notification source we want to bridge into the channel

### Key design decisions

- Use `tsx` + Node (not Bun) for portability — no extra runtime to install
- Port: `8788` (matches the docs example, easy to remember)
- One-way channel only (no reply tool) — Claude reads CI events and acts autonomously
- `setup.sh` detects whether `cc` alias exists in each shell rc file and updates vs. adds
- E2E test: headless `claude --print` session, curl the webhook, check output contains a response

---

## Tasks

### Task 1: Create `channel/webhook.ts`

**What:**
- MCP server using `@modelcontextprotocol/sdk` over stdio transport
- Declares `capabilities.experimental['claude/channel']: {}` (one-way, no tools capability)
- `instructions` string: tells Claude events are CI notifications arriving as `<channel source="webhook" ...>`, one-way, act on them autonomously
- Starts HTTP server on `127.0.0.1:8788` using Node's built-in `http` module (no Bun)
- On every `POST /`: reads body, calls `mcp.notification({ method: 'notifications/claude/channel', params: { content: body, meta: { path, method } } })`
- Returns `200 ok`
- Shebang: `#!/usr/bin/env tsx`

**File:** `/Users/yonichechik/.claude/_clones/claude-channel/channel/webhook.ts`

---

### Task 2: Create `channel/package.json`

**What:**
- `name`: `"claude-channel-webhook"`
- `version`: `"0.0.1"`
- `type`: `"module"`
- `dependencies`: `@modelcontextprotocol/sdk`, `tsx`, `zod` (needed by MCP SDK types)
- `scripts`: `{ "start": "tsx webhook.ts" }`
- No test runner needed here (e2e is shell-based)

**File:** `/Users/yonichechik/.claude/_clones/claude-channel/channel/package.json`

---

### Task 3: Create `channel/.mcp.json`

**What:**
- Registers the webhook server so Claude Code can spawn it
- Command: `node`, args: `["--import", "tsx/esm", "/Users/yonichechik/.claude/channel/webhook.ts"]`
  - OR simpler: command `npx`, args `["tsx", "/Users/yonichechik/.claude/channel/webhook.ts"]`
- Use absolute path (`/Users/yonichechik/.claude/channel/webhook.ts`) so it works from any project directory
- This file is meant to be copied to `~/.claude/.mcp.json` (or symlinked)

**File:** `/Users/yonichechik/.claude/_clones/claude-channel/channel/.mcp.json`

```json
{
  "mcpServers": {
    "webhook": {
      "command": "npx",
      "args": ["tsx", "/Users/yonichechik/.claude/channel/webhook.ts"]
    }
  }
}
```

---

### Task 4: Create `channel/setup.sh`

**What:**
- `npm install` inside `channel/` dir
- Copies (or symlinks) `channel/.mcp.json` to `~/.claude/.mcp.json` (with backup if exists)
- Updates `cc` alias in `~/.zshrc` and `~/.bashrc`:
  - **Detect logic**: grep for `alias cc=` in each file
  - If found: use `sed` to replace the existing line in-place
  - If not found: append the new alias line
- New alias value: `alias cc="claude --dangerously-load-development-channels server:webhook"`
- Print confirmation messages at each step

**File:** `/Users/yonichechik/.claude/_clones/claude-channel/channel/setup.sh`

---

### Task 5: Write e2e test script `channel/test_e2e.sh`

**What:**
- Verifies the full pipeline end-to-end: webhook server starts, Claude receives notification, reacts
- Steps:
  1. Start `claude --dangerously-load-development-channels server:webhook --print "wait for input"` in background (headless)
  2. Polling loop (1-sec intervals, max 10 sec per loop): wait until port 8788 is accepting connections (`nc -z 127.0.0.1 8788`)
  3. `curl -s -X POST localhost:8788 -d "CI FAILURE: build failed on main branch. Run ID: test-001. Fix it."` 
  4. Wait for Claude to produce output (poll for process completion or output file, max 10 sec per loop, re-iterate)
  5. Assert output contains expected keywords (e.g. "build", "main", or any non-empty response)
  6. Print PASS/FAIL and exit with appropriate code
- Captures Claude session output to a temp file for assertion
- Cleans up background processes on exit (trap)

**File:** `/Users/yonichechik/.claude/_clones/claude-channel/channel/test_e2e.sh`

---

### Task 6: Update `cc` alias handling — edge cases in `setup.sh`

**What** (refinement of Task 4 — to be handled within the same file):
- `~/.bashrc` may not exist: check with `[ -f ~/.bashrc ]` before grepping/sed; if absent, skip silently (don't create the file)
- Handle quoted variants: `alias cc="claude"` and `alias cc='claude'` — use a regex grep `alias cc=` (no quote specificity) to catch both
- `sed` in-place flag differs: macOS requires `sed -i ''`, Linux uses `sed -i` — detect OS with `uname` and branch accordingly
- Idempotency: running `setup.sh` twice should not duplicate the alias or corrupt the file

---

### Task 7: Install deps and smoke-test locally

**What:**
- Run `npm install` in `channel/`
- Run `npx tsx channel/webhook.ts &` briefly, curl it, check response, kill
- Verify `.mcp.json` is valid JSON
- Verify `setup.sh` is executable and dry-runs without error

**This task is for the implementer to verify after creating all files — not a file to create.**
