---
name: "continue-feature"
description: "Resume work on existing feature clone"
argument-hint: "[feature-description]"
---

Continues work on an existing feature clone with proper context analysis.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
If empty or missing: "Error: Feature description is required. Please provide a detailed description of the feature you want to continue implementing."

## Process

### Step 1: Search for Existing Clone
List existing clones in _clones/ directory and try to match the feature description:
```bash
ls -1 _clones/
```

If found → Continue to Step 3 (navigate)
If not found → Continue to Step 2

### Step 2: Check for Remote Branch
Check if a remote feature branch exists that matches the description:
```bash
git fetch --prune
git branch -r
```

Review the list of remote branches and match one to the user's feature description.

If found → Run `/create-clone` with the matched branch name, then continue to Step 4
If not found → Exit with error:
- Tell user: "Feature branch not found locally or remotely"
- Suggest: "Use /create-clone <feature-description> to create a new feature clone"

### Step 3: Navigate to Feature Clone
```bash
cd _clones/FEATURE_NAME
```

### Step 4: Gather Context & Analyze Status
Determine feature name from branch: `FEATURE_NAME=$(git rev-parse --abbrev-ref HEAD)`

1. Use explorer subagent to understand the codebase relevant to the feature
2. Check if `plan_$FEATURE_NAME.md` exists — if yes, read it
3. Run `git diff origin/main...HEAD` to see what's been done so far
4. Compare progress against the plan (if exists)

### Step 5: Check State & Report
1. Check git branch state:
```bash
bash ~/.claude/scripts/git_branch_state.sh
```
2. Report to the user:
   - What the feature is about (from plan or branch name)
   - What has been done so far (from git diff)
   - Git branch state (diverged? behind main?)
3. Read and understand the full development workflow:
   - Read the file `~/.claude/skills/feature-loop-scheme/SKILL.md` to understand how we work
   - Based on current progress, tell the user where we are in that workflow
4. Suggest next steps:
   - If behind main or diverged → suggest running `/sync` first
   - Tell the user what the next step in the workflow would be

**STOP HERE.** Do NOT proceed to implementation. Wait for user instructions on what to do next.
