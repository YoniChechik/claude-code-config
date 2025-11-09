# Sync Changes

Creates a commit with professional message generation, pushes to remote, and tracks phase completion.

## Optional commit message hint from user input (can be empty string)
"$ARGUMENTS"

## Process

### Step 1: Analyze Changes for Commit Message
Review staged/unstaged changes to understand:
- Type of change (add, fix, update, refactor)
- Scope and impact
- Key components modified
Do this using git diff. Stage all unstaged changes.

### Step 2: Check Plan Progress
If `task.md` exists, review current phase status:
- Identify which phase is being completed
- Check if this represents a major milestone
- Note any phase transitions

### Step 3: Generate Professional Commit Message
Create structured commit message:

**Format**:
```
Brief description (50 chars max)

- Detailed bullet points of key changes
- Focus on WHY not just WHAT
- Reference phase completion if applicable
```

### Step 4: Update Plan Status (if applicable)
If `task.md` exists and phase completed:
- Mark completed phase with ✓
- Update status documentation

### Step 5: Execute Commit
```bash
git commit -m "$(cat <<'EOF'
[Generated commit message]
EOF
)"
```

### Step 6: Push to Remote
Push changes to remote repository:
```bash
git push
```

If this is the first push and the branch doesn't exist on remote yet:
```bash
git push -u origin HEAD
```

### Step 7: Confirmation
Report commit hash, push status, and summary to user.
