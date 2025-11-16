# Compare Git References

Opens GitLens Search & Compare view to compare two git references (branches, commits, tags) or working tree. Supports main repository and submodules. Automatically clears previous comparisons.

## References from user input
"$ARGUMENTS"

### Validation
- If missing or incomplete: "Error: Two git references are required (can be fuzzy or free text)"
- Find closest matching git references to user inputs (using branches, tags, commits, and worktrees)
- For working tree comparisons: use empty string as ref2
- For submodule comparisons: include submodule path as 3rd argument

## Usage

### Compare two refs in main repository
```bash
curl -X POST http://localhost:$CLAUDE_HELPER_PORT -H "Content-Type: application/json" -d "{\"command\":\"compareReferences\",\"args\":[\"$REF1\",\"$REF2\"]}"
```

### Compare working tree with ref in main repository
```bash
curl -X POST http://localhost:$CLAUDE_HELPER_PORT -H "Content-Type: application/json" -d "{\"command\":\"compareReferences\",\"args\":[\"$REF\",\"\"]}"
```

### Compare two refs in submodule
```bash
curl -X POST http://localhost:$CLAUDE_HELPER_PORT -H "Content-Type: application/json" -d "{\"command\":\"compareReferences\",\"args\":[\"$REF1\",\"$REF2\",\"$SUBMODULE_PATH\"]}"
```

### Compare working tree with ref in submodule
```bash
curl -X POST http://localhost:$CLAUDE_HELPER_PORT -H "Content-Type: application/json" -d "{\"command\":\"compareReferences\",\"args\":[\"$REF\",\"\",\"$SUBMODULE_PATH\"]}"
```

## Examples
- Input: "main HEAD" → Compares main with HEAD in main repo
- Input: "mai origin" → Finds closest matches (e.g., "main" and "origin/main") and compares them
- Input: "develop prod" → Matches "develop" and "production" branches and compares them
- Input: "HEAD~3 working tree" → Compares HEAD~3 with working tree (use empty string for ref2)
- Input: "HEAD~2 HEAD in .claude" → Compares commits in .claude submodule
- Input: "HEAD working tree in .claude" → Compares HEAD with working tree in .claude submodule
