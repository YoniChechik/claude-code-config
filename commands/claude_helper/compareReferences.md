# Compare Git References

Opens GitLens comparison view to compare two git references (branches, commits, tags).

## References from user input
"$ARGUMENTS"

### Validation
- If missing or incomplete: "Error: Two git references are required (can be fuzzy or free text)"
- Find closest matching git references to user inputs (using branches, tags, commits, and worktrees)

## Usage
determine the two references to compare from user args and run:
```bash
curl -X POST http://localhost:3456 -H "Content-Type: application/json" -d "{\"command\":\"compareReferences\",\"args\":[\"$REF1\",\"$REF2\"]}"
```

## Examples
- Input: "main HEAD" → Compares main with HEAD
- Input: "mai origin" → Finds closest matches (e.g., "main" and "origin/main") and compares them
- Input: "develop prod" → Matches "develop" and "production" branches and compares them
