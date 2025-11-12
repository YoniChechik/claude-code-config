# Sync Changes

Merges from origin/main, creates a commit with professional message generation, pushes to remote, and tracks phase completion. Ensures branch head is always >= origin/main.

## Optional commit message hint from user input (can be empty string)
"$ARGUMENTS"

## Process

### Step 1: Merge from Origin/Main

#### 1.1: Execute Merge
```bash
git fetch origin
git merge origin/main
```

#### 1.2: Solve Conflicts (if any)
Git merge automatically:
- **Takes all non-conflicting changes from origin/main** (newer code, new files, etc.)
- **Only creates conflicts** where both branches modified the same lines

For conflicts, resolve by preferring current branch changes.

If conflicts occur:
- Resolve them systematically
- Stage the resolved files
- Continue with the commit process

#### 1.3: Merge Summary
After merge completes, provide brief summary:
- **What was merged**: Source branch and commit range
- **Files added/modified/deleted**: List key changes with file counts
- **Conflicts resolved**: Detail any conflicts encountered and how they were resolved
- **Merge result**: Success status

This ensures our branch is always ahead of origin/main, never diverged.

### Step 2: Analyze Changes for Commit Message
Review staged/unstaged changes to understand:
- Type of change (add, fix, update, refactor)
- Scope and impact
- Key components modified
Do this using git diff. Stage all unstaged changes.

### Step 3: Check Plan Progress
If `task.md` exists, review current phase status:
- Identify which phase is being completed
- Check if this represents a major milestone
- Note any phase transitions

### Step 4: Generate Professional Commit Message
Create structured commit message:

**Format**:
```
Brief description (50 chars max)

- Detailed bullet points of key changes
- Focus on WHY not just WHAT
- Reference phase completion if applicable
```

### Step 5: Update Plan Status (if applicable)
If `task.md` exists and phase completed:
- Mark completed phase with ✓
- Update status documentation

### Step 6: Execute Commit
```bash
git commit -m "$(cat <<'EOF'
[Generated commit message]
EOF
)"
```

### Step 7: Push to Remote
Push changes to remote repository:
```bash
git push
```

If this is the first push and the branch doesn't exist on remote yet:
```bash
git push -u origin HEAD
```

### Step 8: Confirmation
Report commit hash, push status, and summary to user.
