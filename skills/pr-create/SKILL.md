---
name: "pr-create"
description: "Create a pull request. MUST be invoked for ANY request that creates a PR — including 'create a PR', 'open a PR', 'gh pr create', 'submit for review', or any equivalent phrasing. Do NOT call `gh pr create` directly; always run this skill instead."
argument-hint: "[title]"
---

Creates a professional pull request when a feature is complete and ready for review.

## Optional PR title/description hint from user input
"$ARGUMENTS"

## Process

### Step 1: Analyze Feature Branch
- Compare to origin/main:
```bash
git log origin/main..HEAD --oneline
git diff origin/main...HEAD --stat
```
- Erase `plan-*.md` and any other dev/workflow related files and commit. If not sure, ask user for directions.
- **IMPORTANT:** Only erase files that were created by this branch. Never delete files that existed before the branch was created. When in doubt, check `git log origin/main..HEAD -- <file>` to verify the file was added in this branch.

### Step 2: Generate PR Title and Body
Create professional PR content:

**Title Format**: `Feature: [Descriptive title based on plan-*.md and commits]`

**Body Structure**:
```markdown
## Summary
- Key functionality delivered
- Major components implemented
- Value provided to users

## Implementation Details
- Technical approach and architecture decisions
- Integration points with existing codebase
- Notable patterns or utilities used

## Testing
- Unit tests added for core functionality
- Integration tests for end-to-end workflows
- Manual testing performed
```

### Step 3: Create Pull Request
```bash
gh pr create --title "Feature: [Generated title]" --body "$(cat <<'EOF'
[Generated PR body]
EOF
)"
```

### Step 4: PR Success Confirmation
- Display created PR URL

### Step 5: Launch CI Watcher
Invoke the `/ci-watcher` skill to monitor CI for the current branch.
