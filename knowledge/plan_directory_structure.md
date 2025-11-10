# Plan Directory Structure

All feature planning should use a structured `plan/` directory approach for better organization and tracking.

## Directory Structure

### For Single PR Features:
```
plan/
├── high_level.md          # Overview with exec summary
└── task_1_[name].md       # Detailed implementation steps
```

### For Multi-PR Features:
```
plan/
├── high_level.md          # Overview with all tasks
├── task_1_[name].md       # First PR details
├── task_2_[name].md       # Second PR details
└── task_N_[name].md       # Additional tasks as needed
```

## Length Targets

**IMPORTANT: Keep plans concise**

| File | Exec Summary | Total Target | Max |
|------|--------------|--------------|-----|
| high_level.md | 20-30 lines | 70-110 lines | 150 |
| task_N.md | 30-50 lines | 110-200 lines | 250 |

Plans should guide direction, not prescribe implementation. Describe WHAT and WHY, not HOW.

## high_level.md Template

**Purpose**: Quick overview for decision makers
**Audience**: Managers, tech leads
**Length**: 70-110 lines total

```markdown
# Feature: [Name]

## Executive Summary (TLDR)

**What**: [1 sentence describing what we're building]

**Approach**: [High-level strategy - 3-4 bullet points]
- Key approach element 1
- Key approach element 2
- Key approach element 3
- Key approach element 4 (if needed)

**Target State**: [Where we're going - 2-3 bullet points]
- Target characteristic 1
- Target characteristic 2
- Target characteristic 3 (if needed)

**Key Steps**:
1. **[Phase 1]** - [Brief description]
2. **[Phase 2]** - [Brief description]
3. **[Phase 3]** - [Brief description]
4. **[Phase 4]** - [Brief description if needed]

**Success Criteria**:
- Measurable outcome 1
- Measurable outcome 2
- Measurable outcome 3

**Risk Level**: [Low/Medium/High] - [Brief justification]

## Tasks Overview

- [ ] Task 1: [PR Title] - [One line description]
- [ ] Task 2: [PR Title] - [One line description]
- [ ] Task 3: [PR Title] - [One line description]

**Mark with [x] when each task/PR is completed.**

## Sizing Assessment

**Recommendation**: Single PR / Multi-PR
**Rationale**: [Brief explanation in 2-3 sentences]
**Estimated Total Scope**:
- Total lines of code: ~XXX
- Total files affected: ~XX
- Total development time: X-X days
- Test coverage: [minimal/moderate/extensive]

## Architecture Overview

**Components**: [List major components with brief descriptions]
- Component 1: [purpose]
- Component 2: [purpose]
- Component 3: [purpose]

**Data flow**: [Input] → [Processing steps] → [Output]

**Key integration points**: [Where this touches existing code]

## Integration Points

- **Module A**: [How it integrates]
- **Module B**: [How it integrates]
- **Module C**: [How it integrates if applicable]

## Testing Strategy

**Unit tests**: [What to test at unit level]
**Integration tests**: [What workflows to test end-to-end]
**Manual verification**: [What to check manually if applicable]

## Risks & Considerations

1. **[Risk 1]**: [Mitigation in 1-2 sentences]
2. **[Risk 2]**: [Mitigation in 1-2 sentences]
3. **[Risk 3]**: [Mitigation in 1-2 sentences if applicable]

## Alternative Approaches Considered

- **[Approach A]**: [Why not chosen in 1 sentence]
- **[Approach B]**: [Why not chosen in 1 sentence]
```

**Executive Summary Length**: 20-30 lines (lean and action-focused)
**Total File Length**: 70-110 lines

**Note**: Do NOT include Why, Current State, or Scope in high-level exec summary. These belong in task-level plans.

## task_N_[name].md Template

**Purpose**: Implementation guide for engineers
**Audience**: Developer doing the work
**Length**: 110-200 lines total

Each task file is a detailed technical breakdown for one PR:

```markdown
# Task N: [PR Title/Name]

## Executive Summary (TLDR)

**What**: [1 sentence - what this PR delivers]

**Why**: [Why this specific work - 3-4 bullet points]
- Pain point or motivation 1
- Pain point or motivation 2
- Pain point or motivation 3
- Pain point or motivation 4 (if needed)

**Approach**: [How we'll do it - 3-4 bullet points]
- Approach element 1
- Approach element 2
- Approach element 3
- Approach element 4 (if needed)

**Scope**:
- Files: X core files + Y test files
- Code: ~XXX LOC (mostly [movement/new/refactor])
- Testing: [testing approach]
- Timeline: X-Y days

**Current State**: [Where we are - 2-3 bullet points]
- Current characteristic 1
- Current characteristic 2
- Current characteristic 3 (if needed)

**Target State**: [Where we're going - 2-3 bullet points]
- Target characteristic 1
- Target characteristic 2
- Target characteristic 3 (if needed)

**Key Steps**:
1. **[Phase 1]** - [Description]
2. **[Phase 2]** - [Description]
3. **[Phase 3]** - [Description]
4. **[Phase 4]** - [Description]
5. **[Phase 5]** - [Description if needed]

**Success Criteria**:
- Measurable outcome 1
- Measurable outcome 2
- Measurable outcome 3

**Risk Level**: [Low/Medium/High] - [Justification]

## Scope

**What this PR includes:**
- Feature/component 1
- Feature/component 2
- Feature/component 3

**What this PR excludes:**
- Item deferred to later task 1
- Item deferred to later task 2

## Dependencies

**Depends on:**
- [ ] Task X: [name] (if applicable)

**Enables:**
- Task Y: [name] (if applicable)

## Technical Approach

### Files to Create/Modify

- `path/to/file1.py` - [High-level change description]
- `path/to/file2.py` - [High-level change description]
- `path/to/file3.py` - [High-level change description]

### Implementation Strategy

**Phase 1: [Name]** (~X hours)
- [ ] [High-level action 1]
- [ ] [High-level action 2]
- [ ] [High-level action 3]

**Phase 2: [Name]** (~X hours)
- [ ] [High-level action 1]
- [ ] [High-level action 2]

**Phase 3: [Name]** (~X hours)
- [ ] [High-level action 1]
- [ ] [High-level action 2]

**DO NOT include**:
- Full function implementations
- Exact code snippets (short examples OK)
- Line-by-line implementation steps

### Key Design Decisions

1. **[Decision]**: [Rationale in 1-2 sentences]
2. **[Decision]**: [Rationale in 1-2 sentences]
3. **[Decision]**: [Rationale in 1-2 sentences if applicable]

## Testing Strategy

**Unit tests**: Test [components] for [cases]
**Integration tests**: Test [workflows] end-to-end
**Manual checks**: Verify [behaviors] visually/manually

## Success Criteria

- [ ] [Measurable outcome 1]
- [ ] [Measurable outcome 2]
- [ ] [Measurable outcome 3]
- [ ] All tests pass
- [ ] No regressions

## Risks

- **[Risk]**: [Mitigation]
- **[Risk]**: [Mitigation]

## Notes

[Any critical gotchas, context, or considerations - 2-3 sentences max]
```

**Executive Summary Length**: 30-50 lines (comprehensive implementation context)
**Total File Length**: 110-200 lines

## Key Principles for Concise Plans

### 1. Front-Load Critical Information
Every file starts with comprehensive executive summary:
- **high_level.md**: 20-30 lines (decision-focused)
- **task_N.md**: 30-50 lines (implementation-focused)

### 2. Describe Intent, Not Implementation
❌ **Too detailed**: "Extract `apply_annual_utility_filtering()` with signature `def apply_annual_utility_filtering(df: pl.DataFrame, clip_embedding: npt.NDArray[np.float32]) -> pl.DataFrame:`"

✅ **Right level**: "Extract utility filtering logic into separate function"

### 3. High-Level Steps, Not Line-by-Line
❌ **Too granular**: "Move inline imports to top (lines 70-75), Add logger = get_logger(__name__), Add df = calc_is_utility()"

✅ **Right level**: "Extract stage functions with artifact collection"

### 4. Trust the Coder
The coder knows how to:
- Write function signatures
- Handle imports
- Structure code properly
- Follow existing patterns

Don't micromanage - provide direction and constraints, not implementation.

### 5. No Code Blocks (Except Small Examples)
❌ **Too much**: Full 30-line function implementations

✅ **Right amount**:
```python
# Extract functions like:
def apply_stage(df, artifacts):
    # Process data
    # Save artifacts
```

### 6. Different Detail for Different Audiences

**high_level.md** (20-30 line exec summary):
- Omit: Why, Current State, Scope
- Focus: What, Approach, Target, Steps, Success, Risk
- Audience: Decision makers

**task_N.md** (30-50 line exec summary):
- Include: ALL sections (Why, Scope, Current/Target State)
- Focus: Complete implementation context
- Audience: Engineers doing the work

## Checkbox Convention

**Use checkboxes consistently:**
- `[ ]` - Not started
- `[x]` - Completed

**In high_level.md Tasks Overview:**
- Each task represents a complete PR
- Mark `[x]` when PR is merged

**In task_N_[name].md Implementation Steps:**
- Each step is a high-level phase (hours, not minutes)
- Mark `[x]` when phase is completed
- Keep at phase level, not line-by-line

## Naming Convention for Task Files

Format: `task_N_short_descriptive_name.md`

**Examples:**
- `task_1_foundation.md`
- `task_2_core_algorithm.md`
- `task_3_api_integration.md`
- `task_4_testing_polish.md`

**Guidelines:**
- Use lowercase with underscores
- Keep name short but descriptive
- Name should reflect PR title
- Number sequentially (task_1, task_2, etc.)

## When Replanning

**Keep completed task files:**
- Don't delete completed task files
- They serve as implementation history
- Mark as `[x]` in high_level.md Tasks Overview

**Add new task files:**
- Create task_N+1_[name].md for new work
- Update high_level.md with new tasks
- Add "What Changed" section in high_level.md

**Example after replanning:**
```
plan/
├── high_level.md              # Updated with "What Changed" section
├── task_1_foundation.md       # Completed (kept for history)
├── task_2_core_feature.md     # In progress (updated steps)
├── task_3_new_scope.md        # NEW - additional work discovered
└── task_4_polish.md           # NEW - split from oversized task
```

## What to Include vs Exclude

### ✅ Include
- Executive summaries (different lengths per file type)
- Architecture decisions
- Integration points
- Key constraints
- Testing strategy
- Risks and mitigations
- Success criteria

### ❌ Exclude
- Full function implementations
- Line-by-line instructions
- Exact code snippets (except tiny examples)
- Every single edge case
- Detailed logging statements
- Import statements
- Variable names

## Benefits of This Structure

✅ **Faster to read** - 5 min vs 15-20 min
✅ **Easier to update** - High-level plans age better
✅ **Empowers coders** - Room for implementation decisions
✅ **Clear progress tracking** - Tasks Overview shows completion at a glance
✅ **Right detail level** - Different audiences get appropriate context
✅ **Better for PRs** - Each task file maps to one PR
✅ **History preservation** - Completed tasks stay as reference
