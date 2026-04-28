---
name: "ci"
description: "Run the CI watcher script for the current or specified branch"
argument-hint: "[branch]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass via webhook channel.
Launch once per feature — the watcher never exits, so no re-launch is needed.

# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determine branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: get the webhook HTTP port

Call the `get_port` MCP tool (from the webhook server). It returns `PORT:TOKEN` format.
Parse the result: everything before the first `:` is `$PORT`, everything after is `$SESSION_TOKEN`.

# step 3: launch the CI watcher

The watcher sends notifications via curl to the webhook HTTP server on the port obtained above.

Launch with shell-level backgrounding (do NOT use run_in_background=true — the process dies when the subagent exits):
```bash
# Resolve SID8 (8-char session id) from the cwd-session cache written by
# session_start.sh. Inlined (not sourced) so the skill stays self-contained.
# Falls back to "unknown" if the cache file isn't present (e.g. hook didn't run).
_cwd_hash=$(printf '%s' "$PWD" | shasum -a 1 | cut -c1-12)
SID8=$(cat "$HOME/.claude/cache/cwd-session/$_cwd_hash" 2>/dev/null || printf 'unknown')

# Sanitize branch name for use in /tmp file paths: branches like "feature/foo"
# would otherwise produce paths like /tmp/ci_watch_feature/foo.log which fail
# because the parent dir doesn't exist. Replace "/" with "__".
# This matches the BRANCH_KEY logic inside ci_watch_persistent.sh.
BRANCH_KEY="${BRANCH//\//__}"

# Launch watcher with logs going to a branch-keyed file
# so failures are visible instead of silently swallowed.
# 4th arg SID8 distinguishes multiple Claude Code windows on the same branch.
bash ~/.claude/scripts/ci_watch_persistent.sh "$PORT" "$BRANCH" "$SESSION_TOKEN" "${SID8:-unknown}" </dev/null >>/tmp/ci_watch_${BRANCH_KEY}.log 2>&1 &
echo "CI watcher launched for branch $BRANCH (PID $!, log: /tmp/ci_watch_${BRANCH_KEY}.log)"
```

Note: `BRANCH_KEY` is the sanitized form of the branch name (slashes replaced
with `__`) and is used in all `/tmp/ci_watch_*` filenames (state, pr cache,
log, lock). The original `BRANCH` value is still used for git/gh commands and
for human-readable notification messages.
