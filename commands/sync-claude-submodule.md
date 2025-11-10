# Sync .claude Submodule

Initializes or updates the .claude git submodule to ensure it's synced with the latest version from the remote repository.

## Use Cases
1. **New Worktrees**: Initialize .claude submodule in newly created worktrees
2. **Update Submodule**: Pull latest changes from the .claude submodule repository
3. **Fix Missing Submodule**: Repair situations where .claude directory is empty or not initialized

## Process

### Step 1: Check Current Submodule Status
Check if the .claude submodule is initialized and what commit it's currently on:
```bash
git submodule status .claude
```

### Step 2: Initialize and Update Submodule
Initialize the submodule if not already initialized, and update to the latest commit referenced by the parent repository:
```bash
git submodule update --init --recursive .claude
```

### Step 3: Verify Success
Confirm the submodule is properly initialized:
```bash
# Check that .claude directory has contents
ls -la .claude/

# Verify submodule status shows a commit hash without '-' prefix
git submodule status .claude
```

### Step 4: Report Status
Inform user of:
- Whether submodule was initialized or updated
- Current commit hash of .claude submodule
- Confirmation that .claude configuration is now available

## Notes
- This command is safe to run multiple times
- Running it will sync to the commit referenced in the current branch's .gitmodules
- To update to the absolute latest .claude repository changes, use: `git submodule update --remote .claude`
