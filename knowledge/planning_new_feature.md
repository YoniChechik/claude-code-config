# Planning a New Feature from Scratch

This guide describes how to create a comprehensive plan for a brand new feature.

## Step 1: Understand the Feature Request

Parse the feature description to extract:
- **Core requirements**: What must the feature do?
- **User goals**: What problem does it solve?
- **Scope indicators**: Is it small/medium/large?
- **Integration points**: What existing systems will it touch?
- **Constraints**: Performance, timeline, compatibility requirements

## Step 2: Ask Clarifying Questions

Use the AskUserQuestion tool to fill gaps. Focus on 2-4 critical questions:

**Essential questions:**
- What is the primary user-facing goal?
- Are there existing similar features we should align with?
- What are the key integration points (APIs, databases, UI)?
- Should this be delivered incrementally or all at once?
- Are there specific performance/quality requirements?
- What is the priority/timeline?

**Don't ask obvious questions** - only ask what's truly ambiguous.

## Step 3: Explore the Codebase

Use Task tool with `subagent_type="Explore"` to understand current architecture:

```
"Explore the codebase to find features similar to [feature name], focusing on:
- Architecture patterns and conventions used
- Integration points (APIs, databases, interfaces)
- Relevant utilities, libraries, and frameworks
- Testing approaches for similar features"
```

**Look for:**
- Similar existing implementations to learn from
- Utilities you can reuse
- Patterns to follow (or anti-patterns to avoid)
- Test structures to mirror

## Step 4: Assess Feature Sizing

Determine if this should be **Single PR** or **Multi-PR**.

**See @.claude/knowledge/planning_guidelines.md for detailed sizing criteria and PR breakdown guidelines.**

## Step 5: Design the Architecture

Based on codebase exploration, design:

### Component Breakdown
- List all major components needed
- Align with existing patterns
- Keep components focused and modular

### Data Flow
- How does data move through the system?
- What are the inputs and outputs?
- What state needs to be managed?

### API/Interface Definitions
- What functions/classes will be exposed?
- What are their signatures?
- How do they integrate with existing code?

## Step 6: Create Implementation Steps

Break the work into high-level phases, not line-by-line instructions:

**Each phase should:**
- Take 1-4 hours to complete
- Represent a logical unit of work
- Be testable as a whole
- Allow coder discretion on implementation details

**Format with checkboxes (high-level phases):**
```markdown
**Phase 1: Setup** (~2 hours)
- [ ] Create base data structures
- [ ] Set up module structure

**Phase 2: Core Implementation** (~4 hours)
- [ ] Implement core algorithm
- [ ] Add integration with existing modules

**Phase 3: Testing** (~2 hours)
- [ ] Add unit tests
- [ ] Add integration tests
```

**❌ Avoid line-by-line instructions:**
```markdown
- [ ] Add import statement for X
- [ ] Create function signature def foo(a: int) -> str:
- [ ] Add logger = get_logger(__name__)
```

**✅ Use high-level phases:**
```markdown
- [ ] Extract stage functions with artifact collection
- [ ] Refactor main function to orchestrate stages
```

**For Multi-PR approach:**
- Group phases into logical PRs
- Each PR should add value independently
- Order PRs by dependency and risk
- First PR typically establishes foundation

## Step 7: Define Testing Strategy

**Unit tests:**
- What functions/classes need unit tests?
- What edge cases must be covered?
- What mocking is needed?

**Integration/E2E tests:**
- Do we need tests across multiple components?
- What workflows need end-to-end validation?

**Align with existing test patterns** found during exploration.

## Step 8: Identify Risks and Mitigations

**Common risks:**
- Breaking existing functionality
- Performance degradation
- Complex migrations
- External dependency issues
- Unclear requirements

**For each risk:**
- State the risk clearly
- Propose mitigation strategy
- Note if it affects PR ordering

## Step 9: Consider Alternatives

Briefly document other approaches considered:
- What other ways could we solve this?
- Why did we choose the proposed approach?
- What are the tradeoffs?

**Keep this short** - just enough to show you thought it through.

## Step 10: Write Executive Summaries

**CRITICAL**: Every plan file starts with a comprehensive executive summary.

### High-Level Plan (high_level.md)

**Executive Summary: 20-30 lines (lean and action-focused)**

Include these sections:
- **What**: 1 sentence
- **Approach**: 3-4 bullets
- **Target State**: 2-3 bullets
- **Key Steps**: 3-4 numbered phases
- **Success Criteria**: 3 bullets
- **Risk Level**: Assessment with justification

**Omit**: Why, Current State, Scope (those go in task files)

### Task-Level Plan (task_N.md)

**Executive Summary: 30-50 lines (comprehensive implementation context)**

Include ALL sections:
- **What**: 1 sentence
- **Why**: 3-4 bullets
- **Approach**: 3-4 bullets
- **Scope**: Files, LOC, testing, timeline
- **Current State**: 2-3 bullets
- **Target State**: 2-3 bullets
- **Key Steps**: 3-5 numbered phases
- **Success Criteria**: 3 bullets
- **Risk Level**: Assessment with justification

**Why the difference?**
- High-level = Quick decision-making document for managers/tech leads
- Task-level = Implementation guide for engineers doing the work

## Step 11: Write the Plan Documents

Create a `plan/` directory with structured documentation.

**See @.claude/knowledge/plan_directory_structure.md for complete structure details, templates, and conventions.**

### Directory Structure Summary

**For Single PR:**
```
plan/
├── high_level.md          # Overview with exec summary
└── task_1_[name].md       # Detailed implementation steps
```

**For Multi-PR:**
```
plan/
├── high_level.md          # Overview with all tasks
├── task_1_[name].md       # First PR details
├── task_2_[name].md       # Second PR details
└── task_3_[name].md       # Third PR details (if needed)
```

**Reference @.claude/knowledge/plan_directory_structure.md for complete templates.**

## Best Practices

**See @.claude/knowledge/planning_guidelines.md for comprehensive best practices.**
