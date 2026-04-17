#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/YoniChechik/claude-code-config.git"
CLAUDE_DIR="$HOME/.claude"

# --- Git-enable ~/.claude if not already a git repo ---
if [ ! -d "$CLAUDE_DIR/.git" ]; then
  echo "==> Git-enabling $CLAUDE_DIR"
  TMP_DIR="$(mktemp -d)"
  git clone "$REPO_URL" "$TMP_DIR"
  mv "$TMP_DIR/.git" "$CLAUDE_DIR/"
  rm -rf "$TMP_DIR"
  cd "$CLAUDE_DIR"
  git reset --hard HEAD
  echo "    Done. Continuing setup from $CLAUDE_DIR"
fi

SCRIPT_DIR="$CLAUDE_DIR"
CHANNEL_DIR="$SCRIPT_DIR/channel"
MCP_TARGET="$HOME/.claude.json"

echo "==> Installing npm dependencies in $CHANNEL_DIR"
cd "$CHANNEL_DIR"
npm install

# --- Register webhook MCP server directly in ~/.claude.json (no .mcp.json file needed) ---
echo "==> Registering webhook MCP server in $MCP_TARGET"
node -e "$(cat <<'NODEJS'
  const fs = require('fs');
  const path = require('path');
  const target = process.argv[1];
  const homeDir = process.argv[2];

  // Build the webhook MCP entry using $HOME so the path is portable
  const webhookEntry = {
    command: "npx",
    args: ["tsx", path.join(homeDir, ".claude", "channel", "webhook.ts")]
  };

  // Load existing config or start fresh
  let config = {};
  if (fs.existsSync(target)) {
    config = JSON.parse(fs.readFileSync(target, 'utf8'));
  }

  // Add/update the webhook entry under mcpServers
  config.mcpServers = { ...config.mcpServers, webhook: webhookEntry };
  fs.writeFileSync(target, JSON.stringify(config, null, 2) + '\n');
NODEJS
)" -- "$MCP_TARGET" "$HOME"
echo "    Registered webhook MCP server in $MCP_TARGET"

# --- Update cc alias ---
NEW_ALIAS='alias cc='"'"'claude --dangerously-load-development-channels server:webhook'"'"''

update_alias() {
  local rc_file="$1"
  if [ ! -f "$rc_file" ]; then
    return
  fi

  # Remove any existing cc alias line, then append the new one
  if grep -q 'alias cc=' "$rc_file"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' '/^alias cc=/d' "$rc_file"
    else
      sed -i '/^alias cc=/d' "$rc_file"
    fi
  fi
  printf '%s\n' "$NEW_ALIAS" >> "$rc_file"
  echo "    Updated cc alias in $rc_file"
}

echo "==> Updating cc alias"
update_alias "$HOME/.zshrc"
update_alias "$HOME/.bashrc"

echo ""
echo "==> Done! Restart your shell or run: source ~/.zshrc"
echo "    Then start Claude with: cc"
