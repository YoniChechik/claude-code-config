# Merge Branch

Merges changes from a source branch into the current branch with conflict resolution and validation.

## Optional merge instructions from user input (can specify source branch or merge strategy)
"$ARGUMENTS"

## Process

### Step 1: Parse Merge Arguments
- Default source branch: `origin/main`
- Parse user arguments for:
  - Custom source branch (e.g., "origin/develop", "feature/xyz")
  - Other custom instructions (e.g.: if any conflicts exist, don't solve them)

### Step 2: Execute Merge
```bash
# Fetch and merge (default: origin/main)
git fetch origin
git merge $SOURCE_BRANCH
```

Default: `git merge origin/main`

## Step 3: Solve conflicts
Git merge automatically:
- **Takes all non-conflicting changes from origin/main** (newer code, new files, etc.)
- **Only creates conflicts** where both branches modified the same lines

For conflicts, resolve by preferring current branch changes (unless user instructed otherwise).

DON'T commit anything. Let user review it first.

### Step 4: Summary Report
Provide comprehensive merge summary:
- **What was merged**: Source branch and commit range
- **Files added/modified/deleted**: List key changes with file counts
- **Conflicts resolved**: Detail any conflicts encountered and how they were resolved
- **Merge result**: Success status and commit hash
- suggest running `/sync` command to finalize changes.
