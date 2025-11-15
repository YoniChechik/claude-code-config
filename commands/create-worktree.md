# Create Feature Worktree

Creates a git worktree for isolated feature development. This is a shared utility command used by other feature commands.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description."

## Process

### Step 1: Parse Feature Description
- Decide on feature name based on description
- Convert feature name to kebab-case for branch naming
- Validate description is sufficient for planning

### Step 2: Create Git Worktree
Set up isolated feature branch from origin/main (unless user stated a different branch)
```bash
# cd into main submodule
cd main_submodule
# Create worktree beside the current directory
git worktree add ../$FEATURE_NAME -b $FEATURE_NAME origin/main
# Move to new worktree dir
cd ../$FEATURE_NAME
```

### Step 3: Set Terminal Title
/setTerminalTitle "$FEATURE_NAME"

### Step 4: Notify User
Tell user the worktree has been created at `./$FEATURE_NAME`

**FROM NOW ALL NEW WORK SHOULD ONLY BE DONE IN THIS FEATURE DIR**
