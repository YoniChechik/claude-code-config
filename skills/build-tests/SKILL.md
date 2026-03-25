---
name: "build-tests"
description: "Plan and build tests for the current feature"
argument-hint: "[context or focus area]"
---

# Build Tests Mode

Plan and build tests for the current feature branch.

## Additional test focus
"$ARGUMENTS"

If provided, the above gives optional extra constraints or focus areas for test planning. By default, the skill plans and builds tests for all current branch changes without needing any arguments.

## Process

Use a subagent to carry out the following 2 phases sequentially:

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

Write tests following the test plan from Phase 1. Run all tests and fix any failures before finishing.

#### Mocking Rules — CRITICAL

**Unit tests — mocks are fine:**
- Mocks are the standard way to isolate the unit under test. Use them to stub dependencies so you can test one module in isolation.
- NEVER mock the code under test itself — that defeats the purpose.
- Keep mocks focused: if you need more than 2-3 mocks in a single test, the design may need rethinking.

**Integration tests — NO mocks:**
- Wire real components together. The whole point is verifying that real modules work as a system.
- Use real instances of data structures, models, and value objects.
- Invest in proper test fixtures and factories instead of mocking to avoid setup.
- The ONLY acceptable exceptions: external services (APIs, network calls), time/randomness, slow/flaky third-party libs.

**General rules:**
- Integration tests are the bulk of the test suite — they catch the bugs that matter most.
- Unit tests complement them for fast feedback on isolated logic.
- E2E tests: few but critical — verify complete user-facing workflows.
