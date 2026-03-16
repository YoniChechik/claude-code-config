---
name: "review-tests"
description: "Review and fix tests for quality issues"
argument-hint: "[context or focus area]"
---

# Review Tests Mode

Review all tests for quality issues and fix any problems found.

## Additional review focus
"$ARGUMENTS"

If provided, the above gives optional extra constraints or focus areas for the test review. By default, the skill reviews all tests for quality issues without needing any arguments.

## Process

Use a subagent with `subagent_type="coder-agent"` to carry out the following:

### Test Review

Review ALL written tests for quality issues:

- **Mock abuse**: tests that mock so much they're testing mock behavior, not real code
- **Shallow coverage**: tests that only check happy paths
- **Missing edge cases**: empty inputs, None values, boundary conditions, error scenarios
- **Tautological tests**: tests that assert the mock returns what you told it to return
- **Test isolation**: each test must be independent, no shared mutable state
- **Meaningful assertions**: no `assert True`, no asserting only that no exception was thrown
- **Test names**: should describe the behavior being tested, not the implementation

Fix any issues found, then run tests one final time to confirm everything passes.
