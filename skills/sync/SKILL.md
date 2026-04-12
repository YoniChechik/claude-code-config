---
name: "sync"
description: "Merge main, commit changes, and push"
argument-hint: "[message]"
---

Merges from origin/main, commits any local changes with professional message generation, and pushes to remote. This ensures the current branch is always ahead of (or equal to) origin/main, never behind or diverged.

**Goal**: Current branch HEAD >= origin/main (no divergence, no outdated commits)

## Optional commit message hint from user input (can be empty string)
"$ARGUMENTS"

## Process

### Step 1: Fetch and Merge
```bash
bash ~/.claude/skills/sync/sync_merge.sh
```
Parse the JSON output. If `conflicts` is true (exit code 1), resolve conflicts:
- Resolve by preferring current branch changes
- Stage resolved files
- Complete the merge commit

Provide brief merge summary if merge occurred.

### Step 2: Analyze Changes for Commit Message
Review staged/unstaged changes using `git diff` to understand type, scope, and impact.
Stage all unstaged changes with `git add -A`.
If no changes exist, skip to Step 5.

### Step 3: Check Plan Progress
If `plan-*.md` exists, review phase status and note completions.

### Step 4: Generate Commit Message
Create structured commit message:
```
Brief description (50 chars max)

- Detailed bullet points of key changes
- Focus on WHY not just WHAT
- Reference phase completion if applicable
```
Use the user's hint from `$ARGUMENTS` if provided.

### Step 5: Commit, Push, and Verify
If changes exist from Step 2:
```bash
bash ~/.claude/skills/sync/sync_commit_push.sh "GENERATED_COMMIT_MESSAGE"
```
Parse the JSON output. Check `verified` is true. If not, report issue.
If no changes, just report already synced.

### Step 6: Confirmation
Report commit hash, push status, and summary to user.

**Final State**: Current branch >= origin/main (ahead or equal, never behind or diverged)
