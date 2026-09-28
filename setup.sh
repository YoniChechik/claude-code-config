#!/usr/bin/env bash
# Claude Code / shell environment setup. Dual-purpose file:
#
#   1. Sourced from ~/.zshrc on every interactive shell start (`source
#      ~/.claude/setup.sh`) - defines the manual terminal-title override
#      mechanism (`title` / `title-reset`) on top of oh-my-zsh's auto-title
#      hooks. This half only runs when $ZSH_VERSION is set (i.e. actually
#      being sourced by zsh) and must NEVER fall through into the installer
#      body below - a new shell tab must not re-run installer side effects
#      (git clone, MCP config rewrite) on every start.
#
#   2. Executed directly - `bash <(curl -fsSL .../setup.sh)` per README.md -
#      as a one-time bootstrap for a fresh ~/.claude checkout: git-enables
#      the directory and drops retired MCP registrations. This half only
#      runs when NOT sourced from zsh.

if [ -n "${ZSH_VERSION:-}" ]; then
  # --- Manual terminal title override (keeps oh-my-zsh auto-title by default) ---
  # Global flag: 0 = oh-my-zsh auto-titles as usual, 1 = a manual `title` is in effect.
  typeset -g TITLE_OVERRIDE=0

  # oh-my-zsh's omz_termsupport_precmd/preexec (lib/termsupport.zsh) call its own
  # `title` helper internally. We redefine `title` below as a public CLI, so
  # preserve copies of the original functions with their internal `title` calls
  # rewritten to a private alias, so auto-titling keeps working when not overridden.
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

  # Public CLI: `title "NAME"` pins the tab title until `title-reset` runs.
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
  # here and never reach the closing message below.
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

  echo ""
  echo "==> Done! Restart your shell or run: source ~/.zshrc"
  echo "    Then start Claude with: claude"
fi
