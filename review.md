# Code Review Report

**Date**: 2026-03-16
**Branch**: test-plan-review-skill
**Reviewer**: Code Review Agent

## Summary

This branch adds two new skills (`/test` and `/review`), updates the `/plan` skill with anti-mocking testing philosophy, and restructures the `feature-loop-scheme` to incorporate the new skills with a proper test step and parallelized quality+review. All changes are markdown skill configuration files -- no application code was modified.

The changes are well-structured, internally consistent, and faithfully implement the plan. The new test skill provides a clear 3-phase workflow (plan, build, review) with strong anti-mocking guidance. The review skill correctly wraps the existing `reviewer-agent` without modifying it. The feature-loop-scheme is cleanly updated with the new step ordering.

**Overall Status**: APPROVED

## Code Review Findings

### BLOCKING Issues

None found. All changes are markdown configuration files. No code patterns to evaluate for fail-fast violations.

### High Priority

None found.

### Medium Priority

**1. Test skill does not specify subagent_type** -- `skills/test/SKILL.md` line 16
- Severity: MEDIUM
- The test skill says "Use a subagent to carry out the following 3 phases sequentially" but does not specify which `subagent_type` to use. The review skill explicitly specifies `subagent_type="reviewer-agent"`, and the plan skill says "Use a subagent" (also without a type). Since the test skill involves writing code (Phase 2: Test Building), it likely needs `subagent_type="coder-agent"` to have write access. Without specifying, the orchestrator may use the default general-purpose subagent, which per `CLAUDE_append_to_user_prompt_main_agent_only.md` should be avoided in favor of `coder-agent`.
- Suggested fix: Change line 16 to `Use a subagent with subagent_type="coder-agent" to carry out the following 3 phases sequentially:`

**2. Review skill step numbering implies ordering that may conflict with reviewer-agent workflow** -- `skills/review/SKILL.md` lines 18-21
- Severity: MEDIUM
- The review skill says "Before starting the review, the subagent should: 1. Read the plan file for context..." This implies a pre-step before the reviewer-agent's own Step 1. However, the reviewer-agent's workflow starts with "Step 1: Identify Changed Files". The phrasing could be clearer -- "Before starting the review" correctly conveys that this is a pre-step, but since the reviewer-agent already has its own numbered steps, this could lead to the subagent being confused about workflow ordering.
- Suggested fix: This is minor and the current phrasing is likely sufficient. Optionally, rephrase to: "First, read the plan file (`plan-*.md`) for context, then follow the full review workflow as defined in `agents/reviewer-agent.md`."

**3. Anti-mocking rules are duplicated between plan and test skills** -- `skills/plan/SKILL.md` lines 68-74 and `skills/test/SKILL.md` lines 38-52
- Severity: MEDIUM
- The same anti-mocking rules appear in both the plan skill and the test skill. The plan file acknowledges this is intentional ("same rules as in the test skill, so the coder-agent sees them too during implementation"). This is a deliberate design choice for visibility, but it creates a maintenance burden -- if the rules change, both files must be updated. Consider extracting the rules to a shared knowledge file (e.g., `knowledge/testing_philosophy.md`) and referencing it with `@knowledge/testing_philosophy.md` from both skills.
- Suggested fix: For now this is acceptable given the intentional duplication documented in the plan. If the rules evolve, extract to a shared file.

### Low Priority / Suggestions

**4. Inconsistent dash style** -- across multiple files
- Severity: LOW
- The plan skill uses `--` (double dash) for em-dashes in several places (e.g., "integration-first, anti-mocking:" and "just call them"), while the test skill uses ` -- ` (with spaces). Both are acceptable but inconsistent. The third commit message says "Fix consistency and formatting in skill files" but some inconsistency remains.
- Minor stylistic note, not actionable.

**5. Feature-loop-scheme Step 2 still has informal language** -- `skills/feature-loop-scheme/SKILL.md` line 17
- Severity: LOW
- "this will be populated with more fine grained tasks after the plan will be written." -- lowercase start and informal grammar. The rest of the file was cleaned up in this branch but this line was left as-is.
- Suggested fix: Capitalize and rephrase: "This will be populated with fine-grained tasks after the plan is written."

**6. Test skill Phase 1 output format unspecified** -- `skills/test/SKILL.md` lines 23-28
- Severity: LOW
- Phase 1 says to "Produce a test plan" covering several areas, but does not specify where to write it (to a file? just as context for Phase 2?). Since it is a single subagent running all 3 phases sequentially, the plan presumably stays in the conversation context. This is fine, but if the test plan should be persisted (like the feature plan is written to `plan-*.md`), that should be specified.
- Suggested fix: If persistence is desired, add an instruction like "Write the test plan to `test-plan.md` in the current directory." Otherwise, this is fine as-is.

**7. Plan skill still says "EVERY FEATURE MUST INCLUDE TESTS"** -- `skills/plan/SKILL.md` line 61
- Severity: LOW
- Since testing is now handled by a dedicated `/test` skill in a separate step, this directive in the plan skill is now more about the plan describing what to test rather than the coder-agent writing tests during implementation. The subsequent line clarifies this, but the bold "EVERY FEATURE MUST INCLUDE TESTS" could give the coder-agent the impression it should write tests during implementation rather than deferring to the test phase.
- The follow-up line ("Tests are written and reviewed in a separate /test phase after implementation") mitigates this. Consider rephrasing to: "EVERY FEATURE MUST INCLUDE TESTS -- these are planned here and built in the /test phase."

## Test Results

No automated tests are applicable. All changes are markdown skill configuration files. The repository has BATS shell tests, but none are related to skill markdown content. Manual verification was performed by reviewing the diff against the plan.

## Files Reviewed

| File | Status | Notes |
|------|--------|-------|
| `skills/test/SKILL.md` | NEW | Well-structured 3-phase test skill. Missing explicit subagent_type. |
| `skills/review/SKILL.md` | NEW | Clean wrapper around reviewer-agent. Works as intended. |
| `skills/plan/SKILL.md` | MODIFIED | Testing section properly updated with anti-mocking philosophy. Old testing goblet replaced. |
| `skills/feature-loop-scheme/SKILL.md` | MODIFIED | Step ordering updated correctly. Quality+Review parallelization documented. |
| `plan-test-plan-review-skill.md` | NEW | Plan file. Well-written with clear rationale and task breakdown. |
| `agents/reviewer-agent.md` | UNCHANGED | Correctly left untouched -- the review skill wraps it. |
| `skills/quality/SKILL.md` | UNCHANGED | Agent 6 (Test Integrity Review) remains complementary to the new test skill. |
| `CLAUDE_append_to_user_prompt_main_agent_only.md` | UNCHANGED | Agent preferences section still valid with new skill structure. |

## Consistency Verification

- No stale references to `Task tool with subagent_type="reviewer-agent"` remain in active skill/agent files (only in the plan document, which is expected).
- The feature-loop-scheme correctly uses `/test`, `/quality`, `/review`, `/plan`, and `/pr-create` skill invocations.
- The review skill correctly references `agents/reviewer-agent.md` and `subagent_type="reviewer-agent"`.
- Quality skill's Agent 6 (Test Integrity Review) is complementary, not redundant, with the new test skill -- quality checks the diff for test regressions, while the test skill proactively writes and reviews tests.
