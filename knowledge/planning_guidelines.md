# Planning Guidelines and Best Practices

Shared guidelines for feature planning and replanning.

## Development Philosophy

### MVP-First Approach
- Start with minimal working version before adding tests
- Build the smallest thing that demonstrates the feature works
- Get feedback early, iterate based on learnings
- Add comprehensive tests and polish after core works

### Small & Modular
- Break features into small, testable increments
- Each piece should be independently verifiable
- Prefer multiple small PRs over one large PR

### Pattern-Aligned
- Follow existing codebase architecture and utilities
- Reuse existing patterns and conventions
- Don't reinvent what already exists

### Phase-Based Implementation
- **Phase 1: Core** - Minimal working implementation
- **Phase 2: Tests** - Comprehensive test coverage
- **Phase 3: Integration** - Connect with other systems
- **Phase 4: Polish** - Error handling, edge cases, optimization

## Feature Sizing Criteria

Use these indicators to determine if a feature should be single PR or multi-PR:

### Single PR Indicators:
- < 200 lines of code
- < 5 files touched
- Clear boundaries, minimal integration
- 1-2 day completion time
- Limited test coverage needed
- No breaking changes

### Multi-PR Indicators:
- \> 200 lines of code
- Many files across modules
- Complex multi-system integration
- Needs significant refactoring
- Extensive test coverage required
- Breaking changes/migrations
- Benefits from incremental delivery

**When in doubt, prefer breaking into smaller PRs.**

## PR Breakdown Guidelines

### Good PR Split Points:

**By layer:**
- Data models → Business logic → API → UI
- Each layer is a PR

**By feature subset:**
- Read-only feature → Write feature → Advanced features
- Basic CRUD → Validation → Advanced queries

**By risk:**
- Low-risk foundation → Medium-risk integration → High-risk optimization

**By dependency:**
- Standalone utilities → Features that use them → Integration

### Bad Split Points:

❌ Middle of a feature (half-implemented)
❌ Untestable pieces (can't verify in isolation)
❌ Breaking changes split from fixes
❌ Arbitrary file count (splitting just to split)

### Each PR Should:

✅ Add value independently
✅ Be fully testable
✅ Have clear purpose
✅ Be reviewable in < 30 min
✅ Be safe to deploy alone
✅ Move project forward

## Best Practices

### Be Comprehensive but Focused
- Include all necessary implementation detail
- State all needed blocks and tests explicitly
- Don't leave ambiguity about what needs to be done

### Be Practical
- Consider developer velocity
- Balance ideal architecture vs pragmatic delivery
- Account for maintenance burden
- Don't replan too often (analysis paralysis)
- Ship working increments even if plan changes
- Bias toward action over perfect plans

### Be Specific
- Use concrete estimates (not "medium" or "large")
- Reference actual module/file names
- Provide clear rationale for decisions
- Use concrete numbers (LOC, files, days)

### Think Incrementally
- Smaller PRs are better
- Each PR should add value independently
- Consider rollback scenarios

### Follow Existing Patterns
- Explore codebase before planning
- Align with existing architecture
- Reuse utilities and conventions
- Mirror testing approaches

### Be Honest and Communicative
- Don't hide that original plan was wrong (when replanning)
- Explain what you learned
- Show how new plan is better
- Explain replan rationale to user
- Show tradeoffs of different approaches
- Get approval before major direction changes

### Preserve Good Work
- Don't throw away completed work unless truly necessary
- Find ways to ship partial progress
- Learn from what worked
- Keep completed task files for history
