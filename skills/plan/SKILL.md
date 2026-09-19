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
- Other-LLM critique pass must respect this too: reject any suggestion that breaks the work into multiple PRs.

## Feature description from user input
"$ARGUMENTS"

## Process

Use a subagent to carry out the following steps:

### Step 1: Explore & Plan
- Run the `/explore` skill on `$ARGUMENTS` — it covers the codebase side (patterns, architecture, related files, dependencies, integration points) and the web side (common solutions, alternatives, libraries, blog posts about the problem) together.
- **Ask the user multiple questions throughout the process:**
  - Unclear scope or boundaries
  - Multiple valid technical approaches
  - Breaking changes or migration needed
  - Concerns and tradeoffs
- **Decide yourself:**
  - Implementation details, file/function names, code organization, other obvious choices
- **This isn't one-shot.** Explore, ask, and decide can all rerun as many times as needed while planning — a new unknown or problem surfacing mid-plan is normal, not a failure to plan properly the first time. Re-run `/explore` on the new question, ask the user again if it's their call, and fold the answer back into the plan before moving on.

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
- Analyze dependencies between tasks. Group tasks with no dependency on each other and mark them as a **Parallel Group** (e.g. "Parallel Group A: Task 1, Task 2") so they run as parallel subagents instead of serially. Keep dependent tasks in sequence after the group they depend on.

## Other-LLM critique pass

After the plan file is written, run a second-opinion pass before terminating:

- **Critique**: Invoke the `/other-llm` skill on the just-written `plan-$FEATURE_NAME.md`. Ask it to flag weak spots, missing considerations, risky assumptions, bad task sequencing, and unclear acceptance criteria.
- **Triage**: Separate valid points from noise; note any items that are open questions for the user rather than direct fixes.
- **Propose**: Present a short bulleted list of proposed plan changes. Use your structured-question tool (if this environment has one) for concrete accept/reject choices; otherwise plain text.
- **Apply**: Make surgical edits to the plan `.md` for accepted changes — do not rewrite wholesale.
- **Sync session name**: Invoke the `/session-name` skill, passing a short proposed name derived from the feature just planned (e.g. `$FEATURE_NAME` from Step 2, or a short label distilled from the plan's TLDR) as its `$ARGUMENTS`. This keeps the session's displayed name in sync with the feature just planned. `/session-name` handles its own orchestrator-confirmation flow if this runs inside a subagent — no separate ping is needed here.
- **Done**: Tell the user the plan was critiqued by the other LLM and updated, and point them to the final file.

## Presenting the plan to the user

When talking the plan through with the user in chat (not the `plan-*.md` file itself), format each task using the `adhd-structure` skill: 1-line summary, then a 5-line version, then deeper detail only on request.

