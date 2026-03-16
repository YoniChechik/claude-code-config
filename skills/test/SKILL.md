---
name: "test"
description: "Plan, build, and review tests for the current feature"
argument-hint: "[context or focus area]"
---

# Test Mode

Plan, build, and review tests for the current feature branch.

## Feature description from user input
"$ARGUMENTS"

## Process

Use a subagent with subagent_type="coder-agent" to carry out the following 3 phases sequentially:

### Phase 1: Test Planning

- Read the plan file (`plan-*.md`) in the current working directory to understand what was built and why
- Read the implementation code — explore all files changed on this branch
- Run `git diff origin/main...HEAD` to see all changes
- Produce a test plan covering:
  - What modules/functions/classes need testing
  - What behaviors and edge cases to cover
  - What integration points to verify
  - What NOT to mock (and why)
  - What testing approach for each component (unit vs integration vs E2E)

### Phase 2: Test Building

Write tests following the test plan from Phase 1. Run all tests and fix any failures before moving on.

#### Anti-Mocking Rules — CRITICAL

These rules are non-negotiable. Violating them produces tests that verify nothing.

**NEVER mock:**
- The code under test — that defeats the entire purpose of the test
- Simple/pure functions — just call them with real inputs
- Data structures, models, or value objects — use real instances
- To avoid setup — invest in proper test fixtures and factories instead

**ONLY mock:**
- External services (APIs, databases, network calls)
- Time/randomness when determinism is needed
- Third-party libraries that are slow or flaky

**Rules of thumb:**
- Prefer integration tests that wire real components together over unit tests with mocks
- If you need more than 2 mocks in a test, the test design is wrong — rethink the approach
- Tests must exercise real code paths, not mock shadows of them

### Phase 3: Test Review

Review ALL written tests for quality issues:

- **Mock abuse**: tests that mock so much they're testing mock behavior, not real code
- **Shallow coverage**: tests that only check happy paths
- **Missing edge cases**: empty inputs, None values, boundary conditions, error scenarios
- **Tautological tests**: tests that assert the mock returns what you told it to return
- **Test isolation**: each test must be independent, no shared mutable state
- **Meaningful assertions**: no `assert True`, no asserting only that no exception was thrown
- **Test names**: should describe the behavior being tested, not the implementation

Fix any issues found, then run tests one final time to confirm everything passes.
