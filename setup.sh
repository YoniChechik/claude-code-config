#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHANNEL_DIR="/Users/yonichechik/.claude/channel"
MCP_TARGET="$HOME/.claude/.mcp.json"
MCP_SOURCE="$SCRIPT_DIR/.mcp.json"

echo "==> Installing npm dependencies in $CHANNEL_DIR"
cd "$CHANNEL_DIR"
npm install

echo "==> Merging .mcp.json into $MCP_TARGET"
if [ -f "$MCP_TARGET" ]; then
  # Merge: add webhook entry into existing mcpServers
  node -e "
    const fs = require('fs');
    const existing = JSON.parse(fs.readFileSync('$MCP_TARGET', 'utf8'));
    const incoming = JSON.parse(fs.readFileSync('$MCP_SOURCE', 'utf8'));
    existing.mcpServers = { ...existing.mcpServers, ...incoming.mcpServers };
    fs.writeFileSync('$MCP_TARGET', JSON.stringify(existing, null, 2) + '\n');
  "
  echo "    Merged webhook entry into existing $MCP_TARGET"
else
  cp "$MCP_SOURCE" "$MCP_TARGET"
  echo "    Copied $MCP_SOURCE -> $MCP_TARGET"
fi

# --- Update cc alias ---
NEW_ALIAS='alias cc="claude --dangerously-load-development-channels server:/Users/yonichechik/.claude/channel/webhook.ts"'

update_alias() {
  local rc_file="$1"
  if [ ! -f "$rc_file" ]; then
    return
  fi

  if grep -q 'alias cc=' "$rc_file"; then
    # Replace existing alias line (macOS-safe sed)
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^alias cc=.*|$NEW_ALIAS|" "$rc_file"
    else
      sed -i "s|^alias cc=.*|$NEW_ALIAS|" "$rc_file"
    fi
    echo "    Updated cc alias in $rc_file"
  else
    echo "" >> "$rc_file"
    echo "$NEW_ALIAS" >> "$rc_file"
    echo "    Appended cc alias to $rc_file"
  fi
}

echo "==> Updating cc alias"
update_alias "$HOME/.zshrc"
update_alias "$HOME/.bashrc"

echo ""
echo "==> Done! Restart your shell or run: source ~/.zshrc"
echo "    Then start Claude with: cc"
