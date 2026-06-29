---
name: "plan"
description: "Explore codebase and create structured implementation plan"
argument-hint: "[feature-description]"
---
Restate the question in fully concrete terms, making every implicit detail explicit. Then answer.

# Plan Mode

Explore the codebase and create a structured implementation plan.

## HARD CONSTRAINT: ONE FEATURE = ONE PR

**MUST** plan every feature to ship as a **single PR**. Never split into multiple PRs, never propose phased/follow-up PRs, never suggest "PR 1 / PR 2" sequencing.

- All tasks in the plan land together in one branch, one PR.
- If scope feels too big for one PR, ask the user to narrow the scope — do **not** silently split it.
- Codex critique pass must respect this too: reject any suggestion that breaks the work into multiple PRs.

## Feature description from user input
"$ARGUMENTS"

## Process

Use a subagent to carry out the following steps:

### Step 1: Explore & Plan
- Explore existing code patterns and architecture
- Identify related files and components
- Understand dependencies and integration points
- Use web search to find relevant information and examples
- **Ask the user multiple questions throughout the process:**
  - Unclear scope or boundaries
  - Multiple valid technical approaches
  - Breaking changes or migration needed
  - Concerns and tradeoffs
- **Decide yourself:**
  - Implementation details, file/function names, code organization, other obvious choices

### Step 2: Write Plan File

Determine feature name from branch: `FEATURE_NAME=$(git rev-parse --abbrev-ref HEAD)`

Create `plan-$FEATURE_NAME.md` **in the current working directory** (the feature worktree directory) with this structure:

````markdown
# Feature: [Feature Name]

## TLDR
[2 lines typical, max 5 for complex features - WHAT and WHY in plain language]

## Research and References
1 paragraph for simple feature, up to 5 paragraphs for complex features. Add research, references, links to similar implementations, relevant documentation. Include tradeoffs and how this relates to existing codebase patterns and architecture.

### Task 1: [Short Description]
**What:**
- Action 1
- Action 2

### Task 2: [Short Description]
**What:**
- Action 1
- Action 2
````

- Tasks should be as independent as possible, with minimal dependencies between them.
- Tasks should be actionable and specific, not vague or high-level.
- No human in the loop. You can ask/search for relevant CLIs or MCPs.

### Step 3: Add Tasks to Task List
Add the tasks from the plan file to the task list in the relevant positions. Tasks should be added in the order they should be executed, but can be worked on in parallel if they are independent

## Codex critique pass

After the plan file is written, run a second-opinion pass before terminating:

- **Critique**: Invoke the `/codex` skill on the just-written `plan-$FEATURE_NAME.md`. Ask Codex to flag weak spots, missing considerations, risky assumptions, bad task sequencing, and unclear acceptance criteria.
- **Triage**: Separate valid points from noise; note any items that are open questions for the user rather than direct fixes.
- **Propose**: Present a short bulleted list of proposed plan changes. Use AskUserQuestion for concrete accept/reject choices; otherwise plain text.
- **Apply**: Make surgical edits to the plan `.md` for accepted changes — do not rewrite wholesale.
- **Done**: Tell the user the plan was critiqued by Codex and updated, and point them to the final file.

