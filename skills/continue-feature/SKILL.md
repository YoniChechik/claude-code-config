---
name: "continue-feature"
description: "Resume work on existing feature clone"
---

Continues work on an existing feature clone with proper context analysis.


## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description of the feature you want to continue implementing."


## Process

### Step 1: Find Feature Clone
Identify the appropriate clone:
```bash
# List existing clones
ls -1 _clones/
```

If clone doesn't exist, check if feature branch exists remotely and create clone:
```bash
git branch -a | grep feature
REPO_URL=$(git config --get remote.origin.url)

# If remote branch exists:
mkdir -p _clones
git clone -b FEATURE_NAME "$REPO_URL" _clones/FEATURE_NAME
```

If couldn't find a right fit, stop and ask user for clarification.


### Step 2: Navigate to Feature Clone
Tell user to switch to the clone:
```bash
cd _clones/FEATURE_NAME
```

### Step 3: Sync with Main
Run the sync skill to merge from origin/main and commit any local changes:
/sync

### Step 4: Analyze Current Progress
1. Read current git state compared to origin/main to understand context
2. Examine `plan.md` and documentation
3. Identify next steps from the plan

### Step 5: Summarization
- Summarize next steps and ask user how to continue
