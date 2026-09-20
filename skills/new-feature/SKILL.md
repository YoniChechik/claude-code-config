---
name: "new-feature"
description: "Start a new feature: create a worktree, then either the fast pipeline (implement → PR → merge → validate, for small changes or when explicitly asked for 'fast') or the full pipeline (plan → implement → test → review → PR → merge → validate). Use PROACTIVELY, without being asked by name, whenever the user asks to start any new feature or substantial piece of work — 'build X', 'add X feature', 'implement X', 'create X', 'let's start working on X', 'new feature' — anything beyond a trivial one-file edit."
argument-hint: "[feature-description] [fast]"
---

Creates a new feature branch using a git worktree for isolated development, then runs
either the fast pipeline (implement → PR → merge → validate, no planning/tests/review) or the
full pipeline (plan → implement → test → review → PR → merge → validate) end to end.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

- Each time the user asks to plan, run all stages afterwards.
- Each time the user requests a code change/debug, run all stages after implementation.

## Process

### Step 1: Decide Fast or Full
Pick the **fast** track when either is true:
- The description explicitly says "fast" (or an equivalent — "quick", "no planning", "skip tests").
- It's a small, low-risk, well-scoped change: no real design decisions, no new dependencies or architecture, roughly a handful of files.

Otherwise, use the **full** track — the default for anything with real scope or unclear boundaries. State which track was picked and why, in one line, before continuing. On the fast track, skip every step below marked "(skip if fast)"; run the rest in order.

### Step 2: Create Worktree
Run `/create-worktree $ARGUMENTS`. This also sets the terminal tab title and (inside
cmux) the native session name via `/session-name`.

### Step 3: Plan (skip if fast)
Run `/plan $FEATURE_DESCRIPTION` skill.

### Step 4: Implement
- Use a subagent to write code (opus high effort)
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 5: Build Tests (skip if fast)
Run `/build-tests` skill for test planning and building.

### Step 6: Post (skip if fast)
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 7: PR Creation
Run `/pr-create` skill to create a pull request. This also launches the CI watcher in the background automatically.

### Step 8: Merge
Find this environment's CI-watcher script (in Claude Code: `~/.claude/scripts/ci_watch_once.sh`)
and run `bash <that script> push '<branch>'` as a **foreground** Bash call (not
backgrounded) — this blocks until CI settles, superseding the background watcher Step 7
already launched for the same branch (same lock key, so this is an expected, harmless
relaunch/eviction, not a race).

- `CI passed for <branch>` or `No CI checks configured for <branch>` → merge
  immediately: `gh pr merge <PR> --squash --delete-branch`. Report the merge. Do
  **not** ask for confirmation first — this step runs automatically.
- `CI FAILED for <branch>` → do **not** merge. Report the failure and what needs
  fixing, then stop.

### Step 9: Validate on Staging/Production
Run this step only after a successful merge in Step 8.

- Find the deploy target. Check CI/CD config, deploy scripts, or docs (e.g. `.github/workflows`,
  `vercel.json`, `railway.json`, Pulumi stacks) for the staging or production URL.
- Wait for the deploy to finish. Poll deploy status with the platform CLI (e.g. `gh run watch`,
  `vercel ls`, `pulumi stack output`).
- Exercise the changed functionality on the live environment. Curl the new or changed endpoint,
  run a smoke-test command, check logs, and/or use `mcp__claude-in-chrome__*` tools to click
  through the new UI flow when the feature has a UI. Do not stop at "the build succeeded."
- Report the concrete result: what works, with the command or click path used to prove it, or
  what failed, with the actual error.
- If the repo or feature has no staging/production deploy (e.g. a local-only tool), skip this
  step and say so. Do not force it.

### Step 10: Summary
Report a summary of what the feature is, how we implemented it, and what happened at all post-implementation steps (including whether it merged and whether validation passed) — use the `/adhd-structure` skill.
