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

# --- Drop the retired webhook MCP registration from ~/.claude.json ---
# Older installs registered an MCP server pointing at channel/webhook.ts. That
# file is gone, so a leftover entry makes every session start error out.
# Python (not node) because uv/python is the only runtime this repo needs.
echo "==> Removing retired webhook MCP registration from $HOME/.claude.json"
uv run --no-project python - "$HOME/.claude.json" <<'PYTHON'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
if not target.exists():
    sys.exit(0)
try:
    config = json.loads(target.read_text())
except (json.JSONDecodeError, OSError):
    sys.exit(0)
if not isinstance(config, dict):
    sys.exit(0)
servers = config.get("mcpServers")
if not isinstance(servers, dict) or "webhook" not in servers:
    sys.exit(0)
del servers["webhook"]
target.write_text(json.dumps(config, indent=2) + "\n")
print("    Removed mcpServers.webhook")
PYTHON

# --- Update cc alias ---
NEW_ALIAS="alias cc='claude'"

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
