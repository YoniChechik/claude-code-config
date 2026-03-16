# Feature: Test Plan & Review Skill + Reviewer Skill Extraction

## TLDR
Create a dedicated `test` skill (plan/build/review phases) with strong anti-mocking philosophy, extract the reviewer-agent into a `review` skill (following the plan skill pattern of spinning up an agent), update the plan skill with specific testing steps, and update the feature-loop-scheme to use these new skills.

## Research and References

The plan skill (`skills/plan/SKILL.md`) is the reference pattern: it's a skill that says "Use a subagent to carry out the following steps" and lists structured steps. The quality skill (`skills/quality/SKILL.md`) shows how to launch multiple agents in parallel via the Agent tool. The feature-loop-scheme (`skills/feature-loop-scheme/SKILL.md`) is the orchestrator that sequences: plan -> implement -> quality -> review -> fix -> PR -> summary.

Currently, the reviewer-agent is directly invoked from the feature-loop-scheme via `Task tool with subagent_type="reviewer-agent"`. The plan skill already delegates to a subagent. The new skills should follow this same pattern: a SKILL.md that describes what the subagent should do, rather than embedding agent logic directly in the loop.

The current testing guidance in the plan skill is minimal -- just a "Testing Requirements - CRITICAL" section that mentions the testing goblet. It lacks specific anti-mocking rules, concrete instructions on what makes a good test, and any structured test planning/review process. Tests end up mock-heavy because there's no explicit test planning phase and no post-test-writing review that catches mock abuse.

Key architectural decisions:
- **Single `test` skill with 3 phases** (plan, build, review) rather than 3 separate skills. This keeps context unified -- the test planner knows what was planned, the builder knows the plan, the reviewer knows both. Separate skills would lose this context chain.
- **The `review` skill wraps the existing reviewer-agent.md** -- the agent instructions stay in `agents/reviewer-agent.md`, the skill just provides the invocation pattern (like plan skill does).
- **Test step goes after implementation, before quality** -- tests need working code to test against, and quality checks should run on test code too.
- **Parallelization opportunity: quality + review can run in parallel** -- they're independent checks. Test review is part of the test skill and runs before quality/review, so it can't be parallelized with them.

### Task 1: Create `test` skill with plan/build/review phases
**What:**
- Create `skills/test/SKILL.md` following the plan skill pattern (spins up a subagent)
- The skill accepts `$ARGUMENTS` (feature description / context) and runs 3 phases sequentially:

**Phase 1: Test Planning**
- Read the plan file (`plan-*.md`) and the implementation code to understand what was built
- Read `git diff origin/main...HEAD` to see all changes
- Produce a test plan that lists:
  - What modules/functions/classes need testing
  - What behaviors and edge cases to cover
  - What integration points to verify
  - What NOT to mock (and why)
  - What testing approach for each component (unit vs integration vs E2E)

**Phase 2: Test Building**
- Write tests following the test plan from Phase 1
- Anti-mocking rules baked into the instructions:
  - NEVER mock the code under test
  - NEVER mock simple/pure functions -- just call them
  - NEVER mock data structures, models, or value objects
  - NEVER mock to avoid setup -- invest in proper test fixtures and factories instead
  - ONLY mock: external services (APIs, databases, filesystems), time/randomness, third-party libraries that are slow/flaky
  - Prefer integration tests that wire real components together over unit tests with mocks
  - If you need more than 2 mocks in a test, the test design is wrong -- rethink the approach
  - Tests must exercise real code paths, not mock shadows of them
- Run all tests and fix any failures before completing this phase

**Phase 3: Test Review**
- Review all written tests for quality issues:
  - Mock abuse: tests that mock so much they're testing mock behavior, not real code
  - Shallow coverage: tests that only check happy paths
  - Missing edge cases: empty inputs, None values, boundary conditions, error scenarios
  - Tautological tests: tests that assert the mock returns what you told it to return
  - Test isolation: each test should be independent, no shared mutable state
  - Meaningful assertions: no `assert True`, no asserting only that no exception was thrown
  - Test names: should describe the behavior being tested, not the implementation
- Fix any issues found
- Run tests one final time to confirm everything passes

### Task 2: Create `review` skill wrapping reviewer-agent
**What:**
- Create `skills/review/SKILL.md` that follows the plan skill pattern
- The skill says "Use a subagent with subagent_type=reviewer-agent" to carry out the review
- The agent instructions remain in `agents/reviewer-agent.md` (no changes to that file)
- The skill SKILL.md provides the invocation wrapper: read plan file for context, pass the feature description, invoke the reviewer-agent subagent
- The skill should instruct the subagent to write `review.md` (this is already in reviewer-agent.md)

### Task 3: Update plan skill with specific testing guidance
**What:**
- Update `skills/plan/SKILL.md` testing requirements section with:
  - Explicit anti-mocking philosophy (same rules as in the test skill, so the coder-agent sees them too during implementation)
  - Instruction that the plan must include a "Testing Strategy" section for each task, specifying:
    - What to test for that task
    - What approach (unit/integration/E2E)
    - What should NOT be mocked and why
  - Remove or de-emphasize the current "unit tests + mocks" framing from the testing goblet -- reframe as: integration tests are the bulk, unit tests should be mock-free where possible, mocks only for external boundaries
  - Add explicit instruction: "Tests are written and reviewed in a separate test phase after implementation. The plan should describe WHAT to test, but the test skill handles HOW."

### Task 4: Update feature-loop-scheme to use new skills
**What:**
- Update `skills/feature-loop-scheme/SKILL.md` to:
  - Replace Step 4 (direct reviewer-agent invocation) with: `Run /review skill`
  - Add a new step between Implement and Quality: `Run /test skill` for test planning, building, and review
  - Consider parallelizing Quality and Review steps (they're independent -- quality is code style/lint, review is deep code review). This means launching both skills simultaneously and waiting for both to complete, then fixing issues from both.
- New step order:
  1. Plan (`/plan`)
  2. Implement (coder-agent)
  3. Test (`/test`) -- plan tests, build tests, review tests
  4. Quality + Review in parallel (`/quality` and `/review` simultaneously)
  5. Fix issues (from both quality and review)
  6. PR creation (`/pr-create`)
  7. Summary
- Update the "How to start" section to reflect the new steps

### Task 5: Clean up references and verify consistency
**What:**
- Remove the direct `reviewer-agent` invocation reference from `feature-loop-scheme/SKILL.md` (done in Task 4, but verify no stale references remain)
- Search all files for any remaining references to the old pattern (`Task tool with subagent_type="reviewer-agent"`) and update them
- Verify `agents/reviewer-agent.md` doesn't need changes (it should stay as-is since the review skill just wraps it)
- Verify the `CLAUDE_append_to_user_prompt_main_agent_only.md` agent preferences section still makes sense with the new skill structure (it should -- skills invoke subagents, which is fine)
- Verify the quality skill's "Agent 6: Test Integrity Review" still makes sense alongside the new test skill (it does -- quality's test integrity review checks for deleted tests and silent failures in the diff, while the test skill proactively writes and reviews tests; they're complementary)
