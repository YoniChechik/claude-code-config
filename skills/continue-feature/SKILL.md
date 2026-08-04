---
name: "continue-feature"
description: "Resume work on existing feature worktree"
argument-hint: "[feature description or branch name] [optional: what to do next]"
---

Continues work on an existing feature worktree with proper context analysis.

## Input from user
"$ARGUMENTS"

Parse this as natural language. Extract:
1. **Feature identifier** — branch name, feature description, or PR reference that identifies which feature to continue
2. **PR** (optional) — a PR URL or number if mentioned
3. **Next action** (optional) — anything that sounds like instructions for what to work on next

If no input at all: "Error: Please describe which feature you want to continue."

If next action is not provided, gather context and state, then proceed based on the natural next step in the workflow.

## Process

### Step 1a: Search for Existing Worktree
List the registered worktrees and their branches, then try to match the feature description:
```bash
git worktree list
```
Feature worktrees appear at `<repo-root>/.claude/worktrees/<feature-name>` with their branch in brackets. Ignore the main checkout (the repo root itself).

If found → Continue to Step 2 (navigate)
If not found → Continue to Step 1b (check remote branches)

### Step 1b: Check Remote Branches
Check if a remote feature branch exists that matches the description:
```bash
git fetch --prune
git branch -r
```

Review the list of remote branches and match one to the user's feature description.

If found → Run `/create-worktree` with the matched branch name, then continue to Step 4
If not found → Exit with error:
- Tell user: "Feature branch not found locally or remotely"
- Suggest: "Use /new-feature <feature-description> to start a new feature"

### Step 2: Navigate to Feature Worktree
Change to the feature worktree directory using `/cd-permanent .claude/worktrees/$FEATURE_NAME` skill.

### Step 3: Check State
1. Check git branch state:
```bash
bash ~/.claude/scripts/git_branch_state.sh
```
if not synced with main, run the `/sync` skill

### Step 4: Launch CI Watcher
Run `/ci-watcher` skill to launch the CI watcher in the background for the current branch.

### Step 5: Gather Context & Analyze Status
1. Use explorer subagent to understand the codebase relevant to the feature
2. Check if `plan-$FEATURE_NAME.md` exists — if yes, read it
3. Run `git diff origin/main...HEAD` to see what's been done so far
4. Compare progress against the plan (if exists)
5. Run the `/feature-workflow` skill to understand the full workflow when building features

### Step 6: Execute Next Action
**Proceed immediately without asking for approval.** Using all gathered context:
- What the feature is about (from plan or branch name)
- What has been done so far (from git diff)
- Git branch state
- Where we are in the feature-workflow
- The user's requested next action
