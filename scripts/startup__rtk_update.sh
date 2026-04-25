#!/usr/bin/env bash
# Startup hook: silently upgrade RTK via brew and re-run `rtk init -g` to
# keep Claude Code hook files up to date. This script must be fast and
# non-blocking — it runs on every session start.
# Always exits 0 so it never blocks startup.

# ---------------------------------------------------------------------------
# Step 1: Attempt a brew upgrade for RTK.
#   - `brew upgrade` is a no-op (exit 0) when the formula is already
#     at the latest version, so this is cheap when nothing needs updating.
#   - Redirect stderr+stdout to /dev/null so no noise appears in the terminal.
#   - `|| true` ensures a non-zero exit from brew never propagates.
# ---------------------------------------------------------------------------
brew upgrade rtk 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 2: Re-run `rtk init -g` to refresh the global hook files that RTK
#   injects into Claude Code (e.g. the `rtk hook claude` PreToolUse hook).
#   The `-g` flag targets the global Claude config (~/.claude).
#   We force non-interactive mode via `--yes` / `--non-interactive` if
#   supported; pipe `yes` as a fallback so any yes/no prompts auto-accept.
#   Suppress all output; we only care that it runs.
# ---------------------------------------------------------------------------
yes | rtk init -g 2>/dev/null || true

# Always succeed — never block Claude Code startup.
exit 0
