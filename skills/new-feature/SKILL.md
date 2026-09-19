---
name: "new-feature"
description: "Start a new feature: create a worktree, then either the fast pipeline (implement → PR → merge, for small changes or when explicitly asked for 'fast') or the full pipeline (plan → implement → test → review → PR → merge). Use PROACTIVELY, without being asked by name, whenever the user asks to start any new feature or substantial piece of work — 'build X', 'add X feature', 'implement X', 'create X', 'let's start working on X', 'new feature' — anything beyond a trivial one-file edit."
argument-hint: "[feature-description] [fast]"
---

Creates a new feature branch using a git worktree for isolated development, then runs
either the fast pipeline (implement → PR → merge, no planning/tests/review) or the
full pipeline (plan → implement → test → review → PR → merge) end to end.

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

### Step 9: Summary
Report a summary of what the feature is, how we implemented it, and what happened at all post-implementation steps (including whether it merged) — use the `/adhd-structure` skill.
