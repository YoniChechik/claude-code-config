---
name: "continue-feature"
description: "Resume work on existing feature clone"
argument-hint: "[feature description or branch name] [optional: what to do next]"
---

Continues work on an existing feature clone with proper context analysis.

## Input from user
"$ARGUMENTS"

Parse this as natural language. Extract:
1. **Feature identifier** — branch name, feature description, or PR reference that identifies which feature to continue
2. **PR** (optional) — a PR URL or number if mentioned
3. **Next action** (optional) — anything that sounds like instructions for what to work on next

If no input at all: "Error: Please describe which feature you want to continue."

If next action is not provided, gather context and state, then proceed based on the natural next step in the workflow.

## Process

### Step 1a: Search for Existing Clone
List existing clones in _clones/ directory and try to match the feature description:
```bash
ls -1 _clones/
```

If found → Continue to Step 2 (navigate)
If not found → Continue to Step 1b (check remote branches)

### Step 1b: Check Remote Branches
Check if a remote feature branch exists that matches the description:
```bash
git fetch --prune
git branch -r
```

Review the list of remote branches and match one to the user's feature description.

If found → Run `/create-clone` with the matched branch name, then continue to Step 4
If not found → Exit with error:
- Tell user: "Feature branch not found locally or remotely"
- Suggest: "Use /new-feature <feature-description> to start a new feature"

### Step 2: Navigate to Feature Clone
Change to the feature clone directory using `/cd-permanent _clones/$FEATURE_NAME` skill.

### Step 3: Check State
1. Check git branch state:
```bash
bash ~/.claude/scripts/git_branch_state.sh
```
2. Read the file `~/.claude/skills/feature-loop-scheme/SKILL.md` to understand the full workflow

### Step 4: Check for PR & Launch CI Watcher
Check if a PR exists for this branch. If a PR exists (open state): **Launch CI watcher immediately in background** (exception to orchestration-only rule):
  ```
  $HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH
  ```
  Run with `run_in_background=true`. Do NOT wait for results — proceed immediately.

### Step 5: Gather Context & Analyze Status
Determine feature name from branch: `FEATURE_NAME=$(git rev-parse --abbrev-ref HEAD)`

1. Use explorer subagent to understand the codebase relevant to the feature
2. Check if `plan-$FEATURE_NAME.md` exists — if yes, read it
3. Run `git diff origin/main...HEAD` to see what's been done so far
4. Compare progress against the plan (if exists)

### Step 6: Execute Next Action
**Proceed immediately without asking for approval.** Using all gathered context:
- What the feature is about (from plan or branch name)
- What has been done so far (from git diff)
- Git branch state
- Where we are in the feature-loop-scheme workflow
- The user's requested next action (from input after `--`)

Execute the next action now. If behind main or diverged, run `/sync` first, then proceed with the user's requested work.
