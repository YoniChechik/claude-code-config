#!/usr/bin/env bash

if [ -n "${ZSH_VERSION:-}" ]; then
  typeset -g TITLE_OVERRIDE=0

  functions[_omz_orig_title]="$functions[title]"
  functions[_omz_orig_precmd]="${functions[omz_termsupport_precmd]//title /_omz_orig_title }"
  functions[_omz_orig_preexec]="${functions[omz_termsupport_preexec]//title /_omz_orig_title }"

  add-zsh-hook -d precmd omz_termsupport_precmd
  add-zsh-hook -d preexec omz_termsupport_preexec

  _title_override_precmd() {
    (( TITLE_OVERRIDE )) || _omz_orig_precmd
  }

  _title_override_preexec() {
    (( TITLE_OVERRIDE )) || _omz_orig_preexec "$@"
  }

  add-zsh-hook precmd _title_override_precmd
  add-zsh-hook preexec _title_override_preexec

  title() {
    TITLE_OVERRIDE=1
    printf '\e]1;%s\a' "$1"
  }

  title-reset() {
    TITLE_OVERRIDE=0
  }

else
  set -euo pipefail

  REPO_URL="https://github.com/YoniChechik/claude-code-config.git"
  CLAUDE_DIR="$HOME/.claude"

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

  if command -v shfmt >/dev/null 2>&1; then
    echo "==> shfmt already installed ($(shfmt --version))"
  elif command -v brew >/dev/null 2>&1; then
    echo "==> Installing shfmt (the Bash parser the hooks use) via Homebrew"
    if ! brew install shfmt; then
      echo "    WARNING: brew install shfmt failed."
      echo "    Until shfmt is installed, the PreToolUse guards ask before every Bash"
      echo "    command and the PostToolUse Bash hooks skip. Fix brew, then re-run this script."
    fi
  else
    echo "==> Skipping shfmt install: Homebrew not found."
    echo "    Install shfmt from https://github.com/mvdan/sh/releases onto your PATH."
    echo "    Until then, the PreToolUse guards ask before every Bash command and the"
    echo "    PostToolUse Bash hooks skip."
  fi

  echo ""
  echo "==> Done! Restart your shell or run: source ~/.zshrc"
  echo "    Then start Claude with: claude"
fi
