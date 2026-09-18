---
name: "new-feature"
description: "Start a new feature with full planning: create a worktree, then plan, implement, test, review, open a PR, and merge it once CI passes (no confirmation asked). Use PROACTIVELY, without being asked by name, whenever the user asks to start any new feature or substantial piece of work — 'build X', 'add X feature', 'implement X', 'create X', 'let's start working on X', 'new feature' — anything beyond a trivial one-file edit."
argument-hint: "[feature-description]"
---

Creates a new feature branch using a git worktree for isolated development, then runs
the full plan → implement → test → review → PR pipeline end to end.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description for planning."

- Each time the user asks to plan, run all stages afterwards.
- Each time the user requests a code change/debug, run all stages after implementation.

## Process

### Step 1: Create Worktree
Run `/create-worktree $ARGUMENTS`. This also sets the terminal tab title and (inside
cmux) the native session name via `/session-name`.

### Step 2: Plan
Run `/plan $FEATURE_DESCRIPTION` skill.

### Step 3: Implement
- Use a subagent to write code (opus high effort)
- If problems occur, use `/debug` skill to fix them
- After each significant change, commit and push (main agent does this directly)

### Step 4: Build Tests
Run `/build-tests` skill for test planning and building.

### Step 5: Post
Run `/post` skill for quality checks, code review, test review, and lint/format.

### Step 6: PR Creation
Run `/pr-create` skill to create a pull request. This also launches the CI watcher in the background automatically.

### Step 7: Merge
Run `bash ~/.claude/scripts/ci_watch_once.sh push '<branch>'` as a **foreground** Bash
call (not backgrounded) — this blocks until CI settles, superseding the background
watcher Step 6 already launched for the same branch (same lock key, so this is an
expected, harmless relaunch/eviction, not a race).

- `CI passed for <branch>` or `No CI checks configured for <branch>` → merge
  immediately: `gh pr merge <PR> --squash --delete-branch`. Report the merge. Do
  **not** ask for confirmation first — this step runs automatically.
- `CI FAILED for <branch>` → do **not** merge. Report the failure and what needs
  fixing, then stop.

### Step 8: Summary
Report a summary of what the feature is, how we implemented it, and what happened at all post-implementation steps (including whether it merged).
