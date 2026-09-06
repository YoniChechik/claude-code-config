#!/usr/bin/env bash
#
# PostToolUse hook: after a PR is created or merged via `gh pr create`/
# `gh pr merge` OR via `gh api graphql` (createPullRequest/mergePullRequest
# mutations), inject a reminder for CLAUDE (not the user) to start the
# ci-watcher skill and confirm it is watching the right branch. Output goes
# only to hookSpecificOutput.additionalContext (model context) — no
# systemMessage, so nothing is surfaced to the user.

# --- Step 1: read stdin once (can only be consumed a single time).
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

# --- Step 2: only react to PR create/merge, via the `gh pr` subcommand or
# a raw `gh api graphql` mutation (createPullRequest / mergePullRequest).
via_subcommand() { echo "$cmd" | grep -qE '(^|[;&|]\s*)gh pr (create|merge)([[:space:]]|$)'; }
via_graphql() { echo "$cmd" | grep -q 'gh api graphql' && echo "$cmd" | grep -qE 'createPullRequest|mergePullRequest'; }
via_subcommand || via_graphql || exit 0

# --- Step 3: figure out the branch this PR action applies to.
branch=$(git branch --show-current 2>/dev/null)
branch=${branch:-unknown branch}

# --- Step 4: emit context-only JSON (no systemMessage -> not shown to user).
jq -n --arg branch "$branch" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("A PR create/merge command just ran (gh pr create/merge or gh api graphql) on branch \($branch). Before treating this task as done: start the ci-watcher skill (/ci-watcher) for this PR, or if it is already running, verify it is watching \($branch) and not a stale branch.")
  }
}'
