# Continue Feature Development

Continues work on an existing feature worktree with proper context analysis.


## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description of the feature you want to continue implementing."


## Process

### Step 1: Find Feature Worktree
Identify the appropriate worktree:
```bash
git worktree list
```

If worktree doesn't exist, check if feature branch exists and create worktree:
```bash
# cd into main submodule
cd main_submodule
git branch -a | grep feature
# If local branch exists but no worktree:
git worktree add ../FEATURE_NAME FEATURE_NAME
# If only remote branch exists:
git worktree add -b FEATURE_NAME ../FEATURE_NAME origin/FEATURE_NAME
# Move to new worktree dir
cd ../$FEATURE_NAME
```

If couldn't find a right fit, stop and ask user for clarification.

### Step 2: Set Terminal Title
/setTerminalTitle "FEATURE_NAME"

### Step 3: Analyze Current Progress
1. Check if sync with origin/main is needed. if so- run /merge command.
2. Read current git state compared to origin/main to understand context
3. Examine `plan.md` and documentation
4. Identify next steps from the plan

### Step 5: Summarization
- Summarize next steps and ask user how to continue
