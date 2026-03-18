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
- **Deleted tests**: if any test functions/methods were deleted — a deleted test is ONLY acceptable if the code it tested was also deleted. If a test was removed because it was failing, it must be fixed, not deleted. Flag suspicious test deletions.
- **Silent test failures**: tests must fail loudly — no test should be silently skipped or produce false passes because of missing dependencies, fixtures, data, or configuration. Flag patterns like `pytest.importorskip()` without justification, `@pytest.mark.skip` / `@unittest.skip`, `try/except` inside tests that suppresses assertion errors, tests that return early with a pass when a precondition isn't met, `if not X: return` or `if not X: pytest.skip()` patterns. All test dependencies must be explicitly required — if a fixture, data file, or service is needed, the test must fail clearly when it's absent.
- **Test configuration & markers**: flag any changes to test configuration files (pytest.ini, setup.cfg, pyproject.toml test sections, conftest.py) that could silence or skip tests. Flag any new test markers (e.g., `@pytest.mark.slow`, `filterwarnings`, `xfail`) — markers must not be added without user approval. Flag changes to CI test commands that reduce test scope (e.g., adding `--ignore`, `-k "not ..."`, `--deselect`).

Fix any issues found, then run tests one final time to confirm everything passes.
