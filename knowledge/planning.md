# Planning Reference

Quick reference for the planner agent on structure and sizing.

## Plan Directory Structure

**Single PR:**
```
plan/
├── high_level.md       # Overview (70-110 lines, exec summary 20-30 lines)
└── task_1_name.md      # Implementation (110-200 lines, exec summary 30-50 lines)
```

**Multi-PR:**
```
plan/
├── high_level.md       # Overview with all tasks
├── task_1_name.md      # First PR
├── task_2_name.md      # Second PR
└── task_N_name.md      # Additional PRs
```

## File Templates

### high_level.md
```markdown
# Feature: [Name]

## Executive Summary
**What**: [1 sentence]
**Approach**: [3-4 bullets]
**Target State**: [2-3 bullets]
**Key Steps**: [3-4 phases]
**Success Criteria**: [3 bullets]
**Risk Level**: [Low/Medium/High with reason]

## Tasks Overview
- [ ] Task 1: [name] - [description]
- [ ] Task 2: [name] - [description]

## Architecture
[High-level design decisions]

## Risks & Considerations
[Potential issues and mitigations]
```

### task_N_name.md
```markdown
# Task N: [Name]

## Executive Summary
**What**: [1 sentence]
**Why**: [3-4 bullets - rationale]
**Approach**: [3-4 bullets]
**Scope**: Files, LOC, timeline
**Current State**: [2-3 bullets]
**Target State**: [2-3 bullets]
**Key Steps**: [3-5 phases]
**Success Criteria**: [3 bullets]
**Risk Level**: [Assessment]

## Implementation Phases
**Phase 1: [Name]** (~X hours)
- [ ] High-level step (not line-by-line)
- [ ] Another high-level step

**Phase 2: [Name]** (~X hours)
- [ ] High-level step

## Testing Strategy
[What types of tests and coverage]

## Dependencies
[What must be done first]
```

## PR Sizing Guidelines

**Single PR:**
- < 200 LOC
- < 5 files
- 1-2 days work
- Clear boundaries

**Multi-PR:**
- > 200 LOC
- Many files/modules
- Complex integration
- Breaking changes

**Split by:**
- Layer (models → logic → API → UI)
- Feature subset (read → write → advanced)
- Risk (low-risk → high-risk)
- Dependency (foundation → features)

**When in doubt**: Prefer smaller PRs.
