# Compare HEAD with Reference

Opens GitLens comparison view to compare HEAD with another git reference.

## Reference from user input
"$ARGUMENTS"

### Validation
- If empty or missing: "Error: Git reference is required (can be fuzzy or free text)"
- find closest matching git reference to user input (using branches, tags, commits, and worktrees)

## Usage
determine the reference to compare from user args and run:
```bash
curl -X POST http://localhost:3456 -H "Content-Type: application/json" -d "{\"command\":\"compareHead\",\"args\":[\"$REF\"]}"
```

## Examples
- Input: "origin/main" → Compares HEAD with origin/main
- Input: "mai" → Finds closest match (e.g., "main") and compares HEAD with it
- Input: "ORIG" → Matches "ORIG_HEAD" and compares HEAD with it
