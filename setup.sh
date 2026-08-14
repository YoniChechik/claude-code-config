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
# Guarded on uv: under `set -e` a missing uv would abort the whole installer
# here and never reach the cc alias step below.
if command -v uv >/dev/null 2>&1; then
  echo "==> Removing retired webhook MCP registration from $HOME/.claude.json"
  uv run --no-project python - "$HOME/.claude.json" <<'PYTHON'
import json
import os
import sys
import tempfile
from pathlib import Path

target = Path(sys.argv[1])
try:
    config = json.loads(target.read_text())
except FileNotFoundError:
    sys.exit(0)
except (json.JSONDecodeError, OSError) as exc:
    print(f"    WARNING: cannot read {target} ({exc}).", file=sys.stderr)
    print("    Left untouched. If sessions error on a missing", file=sys.stderr)
    print("    channel/webhook.ts, delete mcpServers.webhook by hand.", file=sys.stderr)
    sys.exit(0)
if not isinstance(config, dict):
    sys.exit(0)
servers = config.get("mcpServers")
if not isinstance(servers, dict) or "webhook" not in servers:
    sys.exit(0)
del servers["webhook"]
# Atomic rewrite: this file holds every project, MCP server and history entry,
# and setup.sh usually runs from inside a live Claude session that also writes
# it. A truncating in-place write could destroy all of that on a crash or a
# concurrent write; a sibling temp file plus os.replace cannot.
tmp_name = ""
try:
    mode = target.stat().st_mode & 0o777
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=".claude.json.")
    with os.fdopen(fd, "w") as handle:
        handle.write(json.dumps(config, indent=2) + "\n")
    os.chmod(tmp_name, mode)
    os.replace(tmp_name, target)
except OSError as exc:
    if tmp_name:
        Path(tmp_name).unlink(missing_ok=True)
    print(f"    WARNING: could not rewrite {target} ({exc}).", file=sys.stderr)
    print("    Left untouched; delete mcpServers.webhook by hand.", file=sys.stderr)
    sys.exit(0)
print("    Removed mcpServers.webhook")
PYTHON
else
  echo "==> Skipping webhook MCP cleanup: uv not found."
  echo "    Install uv (https://docs.astral.sh/uv/), then re-run this script."
fi

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
