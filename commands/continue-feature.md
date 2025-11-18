# Continue Feature Development

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
ls -1 ./_clones/
```

If clone doesn't exist, check if feature branch exists remotely and create clone:
```bash
git branch -a | grep feature
REPO_URL=$(git config --get remote.origin.url)

# If remote branch exists:
git clone -b FEATURE_NAME "$REPO_URL" ./_clones/FEATURE_NAME
```

If couldn't find a right fit, stop and ask user for clarification.


### Step 2: Navigate to Feature Clone
Tell user to switch to the clone:
```bash
cd ./_clones/FEATURE_NAME
```

### Step 3: Analyze Current Progress
1. Check if sync with origin/main is needed. if so- run /merge command.
2. Read current git state compared to origin/main to understand context
3. Examine `plan.md` and documentation
4. Identify next steps from the plan

### Step 4: Summarization
- Summarize next steps and ask user how to continue
