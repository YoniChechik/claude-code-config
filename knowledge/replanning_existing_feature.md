# Replanning an Existing Feature

This guide describes how to revise an existing plan based on new findings, analysis, bugs, or scope changes.

## When to Replan

Replanning is needed when:
- **New findings**: Discovered complexity not in original plan
- **Analysis updates**: Better understanding of requirements or architecture
- **Bugs discovered**: Issues revealed gaps in original planning
- **Scope changed**: User added/removed requirements
- **PR too large**: Original plan resulted in oversized PR
- **Dependencies changed**: External factors shifted approach
- **Performance issues**: Original approach won't meet requirements

## Step 1: Assess Current State

**Read the existing plan/ directory:**
- Read `plan/high_level.md` for original scope and tasks overview
- Check which tasks are marked `[x]` as completed
- Read individual `plan/task_N_*.md` files for detailed status
- What was the original PR breakdown?

**Review actual implementation:**
```bash
git diff main...HEAD --stat
git log --oneline main..HEAD
```

**Ask yourself:**
- How many lines of code so far?
- How many files touched?
- Is this tracking to original estimates?
- What unexpected complexity arose?

## Step 2: Identify What Changed

**Clearly articulate the change:**
- What new information do we have?
- What assumptions were wrong?
- What requirements changed?
- What technical issues emerged?

**Examples:**
- "Discovered we need database migration, not in original plan"
- "Feature grew from 150 to 400 LOC due to edge cases"
- "User now needs real-time updates, not polling"
- "Found existing bug that must be fixed first"

## Step 3: Analyze Current PR Size

If the current PR is too large, assess:

**Current PR metrics:**
- Lines of code added/modified
- Number of files touched
- Number of commits
- Complexity of changes (simple edits vs architectural changes)

**Red flags for oversized PR:**
- \> 500 LOC changed
- \> 10 files touched
- Multiple unrelated concerns mixed together
- Would take > 30 minutes to review
- Difficult to write clear PR description
- Hard to test all changes together
- High risk if it needs to be reverted

## Step 4: Propose PR Breakdown (if needed)

If current work is too large, propose how to split it:

### Option A: Split work already done
**When to use**: Have completed too much in one PR

**Approach:**
1. Identify natural boundaries in existing work
2. Create separate branches for each logical piece
3. Cherry-pick commits to appropriate branches
4. Order PRs by dependency

**Example:**
```
Current PR (too big): User auth system - 800 LOC

Split into:
- PR 1: Core auth data structures (200 LOC)
- PR 2: Login/logout endpoints (250 LOC)
- PR 3: Session management (200 LOC)
- PR 4: Permission checking (150 LOC)
```

### Option B: Pause and replan remaining work
**When to use**: Haven't completed full scope yet

**Approach:**
1. Complete current PR with just what's done
2. Create new plan for remaining work
3. Break remaining work into smaller PRs

**Example:**
```
Current PR: Implement 3 of 5 planned features
Action: Ship PR with 3 features, replan remaining 2
```

### Option C: Rollback and restart with better plan
**When to use**: Work went wrong direction, needs redo

**Approach:**
1. Save learning from current attempt
2. Reset branch or create fresh one
3. Create new plan with better approach
4. Start over with proper breakdown

**Only use when necessary** - usually A or B are better.

## Step 5: Update or Rewrite Plan

**See @.claude/knowledge/plan_directory_structure.md for structure details and templates.**

### For Minor Updates:
Keep existing `plan/` directory structure, just update:
- Update `plan/high_level.md` tasks overview with any new tasks
- Revise time estimates in high_level.md
- Update or add individual task files as needed
- Note what changed in "Risks & Considerations"

### For Major Replanning:
Update `plan/` directory:

**Update plan/high_level.md:**
- Add **What Changed** section at top explaining the replan
- Update Tasks Overview with new/revised task list
- Mark completed tasks with `[x]`
- Update architecture if approach changed
- Update estimates and risks

**Update/Add task files:**
- Keep completed task files as-is (for history)
- Update in-progress task files with new steps
- Create new task_N_*.md files for additional PRs
- Mark completed steps with `[x]` in task files

**Example directory after replanning:**
```
plan/
├── high_level.md              # Updated with "What Changed" section
├── task_1_foundation.md       # Completed (kept for history)
├── task_2_core_feature.md     # In progress (updated steps)
├── task_3_new_scope.md        # NEW - additional work discovered
└── task_4_polish.md           # NEW - split from oversized task
```

## Step 6: Propose Clear Action Items

End the replanning with **clear next steps:**

**If continuing current PR:**
```markdown
## Next Steps
- [ ] Complete remaining items in current PR
- [ ] Add tests for new edge cases discovered
- [ ] Update documentation
```

**If splitting PR:**
```markdown
## Next Steps
- [ ] Complete current PR with just [scope]
- [ ] Create new branch for PR 2: [scope]
- [ ] Create new branch for PR 3: [scope]
```

**If changing approach:**
```markdown
## Next Steps
- [ ] Pause current implementation
- [ ] [Specific technical investigation needed]
- [ ] Implement new approach starting with [foundation]
```

## Step 7: Document Lessons Learned

Add to plan.md:

```markdown
## Lessons Learned During Implementation

**What we discovered:**
- [Finding 1]
- [Finding 2]

**What we learned:**
- [Insight 1]
- [Insight 2]

**How plan was adjusted:**
- [Change 1]
- [Change 2]
```

This helps with future planning.

## Guidelines for PR Breakdown

**See @.claude/knowledge/planning_guidelines.md for detailed PR breakdown guidelines.**

## Example: Replanning Oversized PR

**Original plan:** Add caching system (single PR)

**What happened:** Implementation hit 600 LOC and growing

**Replan:**

**Updated plan/high_level.md:**
```markdown
# Feature: Caching System

## What Changed
Original plan underestimated complexity. Cache invalidation and
multi-level caching added significant scope. Current implementation
at 600 LOC with more to go. Split into 3 PRs.

## Executive Summary
Add comprehensive caching system with TTL, invalidation, and Redis support
for improved performance across the application.

## Tasks Overview

- [ ] Task 1: Basic Cache Infrastructure - Simple in-memory cache with TTL
- [ ] Task 2: Cache Invalidation - Smart invalidation on data changes
- [ ] Task 3: Multi-level Cache - Redis integration for distributed cache

## Sizing Assessment
**Recommendation**: Multi-PR (revised from Single PR)
**Rationale**: Cache invalidation and Redis complexity requires 3 separate PRs
**Estimated Total Scope**:
- Total lines of code: ~850
- Total files affected: ~8
- Total development time: 5-6 days
- Test coverage: extensive

[Rest of architecture, integration points, etc.]
```

**Updated plan/task_1_basic_cache.md:**
```markdown
# Task 1: Basic Cache Infrastructure

## Summary
Implement simple in-memory cache with TTL support as foundation for caching system.

## Scope
**What this PR includes:**
- In-memory cache with TTL
- Basic get/set/delete operations
- TTL expiration handling

**What this PR excludes:**
- Cache invalidation (Task 2)
- Redis integration (Task 3)

## Estimated Scope
- Lines of code: ~400
- Files affected: ~3
- Development time: 2 days

## Implementation Steps
- [x] Create cache data structure
- [x] Implement get/set/delete methods
- [ ] Add TTL expiration handling
- [ ] Add unit tests for edge cases
- [ ] Add basic performance benchmarks

[Rest of technical details...]
```

**New plan/task_2_cache_invalidation.md:**
```markdown
# Task 2: Cache Invalidation

## Summary
Add smart cache invalidation triggered by data changes.

## Scope
**What this PR includes:**
- Cache key tracking system
- Invalidation hooks for data changes
- Comprehensive invalidation tests

## Dependencies
**Depends on:**
- [x] Task 1: Basic Cache Infrastructure

## Estimated Scope
- Lines of code: ~200
- Files affected: ~3
- Development time: 2 days

## Implementation Steps
- [ ] Add cache key tracking
- [ ] Implement invalidation hooks
- [ ] Add invalidation tests

[Rest of technical details...]
```

**New plan/task_3_multilevel_cache.md:**
```markdown
# Task 3: Multi-level Cache

## Summary
Add Redis integration for distributed caching with failover support.

[Similar structure for Task 3...]
```

## Best Practices

**See @.claude/knowledge/planning_guidelines.md for comprehensive best practices.**
