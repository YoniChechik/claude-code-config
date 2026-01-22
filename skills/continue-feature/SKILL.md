---
name: "continue-feature"
description: "Resume work on existing feature clone"
---

Continues work on an existing feature clone with proper context analysis.


## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
If empty or missing: "Error: Feature description is required. Please provide a detailed description of the feature you want to continue implementing."

## Process

### Step 1: Find or Create Feature Clone

#### 1.1: Search for Existing Clone
List existing clones in _clones/ directory and try to match the feature description:
```bash
ls -1 _clones/
```

**Decision point**: If local clone found matching the feature description → Continue to Step 2.
**Decision point**: If no local clone found → Continue to 1.2.

#### 1.2: Check for Remote Branch (if no local clone)
If no local clone exists, check if a remote feature branch exists that matches the description:
```bash
git fetch --prune
git branch -a | grep "remotes/origin/feature"
```

**Decision point**: If remote branch found matching the feature description → Continue to 1.3.
**Decision point**: If no remote branch found → Continue to 1.4.

#### 1.3: Clone from Remote (if remote branch exists)
If remote branch exists but no local clone, create the local clone:
```bash
REPO_URL=$(git config --get remote.origin.url)
mkdir -p _clones
git clone -b FEATURE_BRANCH_NAME "$REPO_URL" _clones/FEATURE_BRANCH_NAME
```

After cloning successfully → Continue to Step 2.

#### 1.4: Feature Not Found
If neither local clone nor remote branch exists:
- Tell user: "Feature branch not found locally or remotely"
- Suggest: "Use the create-clone skill to create a new feature clone: /create-clone <feature-description>"
- Exit the skill


### Step 2: Navigate to Feature Clone
Tell user to switch to the clone:
```bash
cd _clones/FEATURE_NAME
```

### Step 3: Sync with Main
Run the sync skill to commit and push.

### Step 4: Analyze Current Progress
1. Read current git state compared to origin/main to understand context
2. Examine `plan.md` and documentation
3. Identify next steps from the plan

### Step 5: Summarization
- Summarize next steps and ask user how to continue
