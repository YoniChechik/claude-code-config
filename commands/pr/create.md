# Create Pull Request

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
- Erase `plan.md` and any other dev/workflow related files and commit. If not sure, ask user for directions.

### Step 2: Generate PR Title and Body
Create professional PR content:

**Title Format**: `Feature: [Descriptive title based on plan.md and commits]`

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
gh pr create --draft --title "Feature: [Generated title]" --body "$(cat <<'EOF'
[Generated PR body]
EOF
)"
```

**Note**: PRs are created in draft mode by default to avoid triggering CI workflows unnecessarily.

### Step 4: PR Success Confirmation
- Display created PR URL

**IMPORTANT**: After creating the PR, do NOT commit any additional changes unless the user explicitly requests it. Wait for user instructions.
