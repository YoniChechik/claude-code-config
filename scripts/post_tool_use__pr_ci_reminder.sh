#!/usr/bin/env bash
#
# PostToolUse hook: after `gh pr create` or `gh pr merge` runs, inject a
# reminder for CLAUDE (not the user) to start the ci-watcher skill and
# confirm it is watching the right branch. Output goes only to
# hookSpecificOutput.additionalContext (model context) — no systemMessage,
# so nothing is surfaced to the user.

# --- Step 1: read stdin once (can only be consumed a single time).
input=$(cat)

# --- Step 2: only react to `gh pr create` / `gh pr merge` commands.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
echo "$cmd" | grep -qE '(^|[;&|]\s*)gh pr (create|merge)([[:space:]]|$)' || exit 0

# --- Step 3: figure out the branch this PR action applies to.
branch=$(git branch --show-current 2>/dev/null)
branch=${branch:-unknown branch}

# --- Step 4: emit context-only JSON (no systemMessage -> not shown to user).
jq -n --arg branch "$branch" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("A `gh pr create`/`gh pr merge` command just ran on branch \($branch). Before treating this task as done: start the ci-watcher skill (/ci-watcher) for this PR, or if it is already running, verify it is watching \($branch) and not a stale branch.")
  }
}'
