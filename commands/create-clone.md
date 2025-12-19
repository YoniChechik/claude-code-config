# Create Feature Clone

Creates a git clone for isolated feature development.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description."

## Process

### Step 1: Parse Feature Description
- Decide on feature name based on description
- Convert feature name to kebab-case for branch naming
- Validate description is sufficient for planning

### Step 2: Create Git Clone
Set up isolated feature branch from origin/main (unless user stated a different branch)
```bash
# Get the current repo URL
REPO_URL=$(git config --get remote.origin.url)

# Create _clones directory if it doesn't exist
mkdir -p _clones

# Create clone in _clones subdirectory with branch name as folder
git clone -b main "$REPO_URL" _clones/$FEATURE_NAME

# Move to new clone directory
cd _clones/$FEATURE_NAME

# Create and checkout the feature branch
git checkout -b $FEATURE_NAME
```

### Step 3: Publish Branch to Remote
Push the empty branch to remote to establish tracking:
```bash
# Push the branch to remote and set upstream
git push -u origin $FEATURE_NAME
```

### Step 4: Sync with Main
/sync

### Step 5: Create Python Virtual Environment (if python project)
Create a virtual environment using uv:
```bash
uv venv
```

### Step 6: Notify User
Tell user:
- The clone has been created at `_clones/$FEATURE_NAME`
- The branch `$FEATURE_NAME` has been published to remote

**FROM NOW ALL NEW WORK SHOULD ONLY BE DONE IN THIS FEATURE DIR**
