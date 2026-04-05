#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHANNEL_DIR="$SCRIPT_DIR/channel"
MCP_TARGET="$HOME/.claude.json"
MCP_SOURCE="$SCRIPT_DIR/.mcp.json"

echo "==> Installing npm dependencies in $CHANNEL_DIR"
cd "$CHANNEL_DIR"
npm install

echo "==> Merging .mcp.json into $MCP_TARGET"
if [ -f "$MCP_TARGET" ]; then
  # Merge: add webhook entry into existing mcpServers
  node -e "$(cat <<'NODEJS'
    const fs = require('fs');
    const target = process.argv[2];
    const source = process.argv[3];
    const existing = JSON.parse(fs.readFileSync(target, 'utf8'));
    const incoming = JSON.parse(fs.readFileSync(source, 'utf8'));
    existing.mcpServers = { ...existing.mcpServers, ...incoming.mcpServers };
    fs.writeFileSync(target, JSON.stringify(existing, null, 2) + '\n');
NODEJS
  )" -- "$MCP_TARGET" "$MCP_SOURCE"
  echo "    Merged webhook entry into existing $MCP_TARGET"
else
  cp "$MCP_SOURCE" "$MCP_TARGET"
  echo "    Copied $MCP_SOURCE -> $MCP_TARGET"
fi

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
