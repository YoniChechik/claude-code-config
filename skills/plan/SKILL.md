---
name: "plan"
description: "Explore codebase and create structured implementation plan"
argument-hint: "[feature-description]"
---

# Plan Mode

Explore the codebase and create a structured implementation plan.

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

Create `plan-$FEATURE_NAME.md` **in the current working directory** (the feature clone directory) with this structure:

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

**Make sure to save all task list and add the plan tasks to the task list in the relevant position.**


## Must Have:

### Testing Requirements - CRITICAL

**EVERY FEATURE MUST INCLUDE TESTS. Features must be verified, not assumed to work.**

Follow the testing goblet (inverted pyramid):
- **Unit tests + mocks**: Foundation layer, test individual functions and classes in isolation
- **Integration tests**: The bulk of tests - verify components work together, test real interactions between modules
- **E2E tests**: Few but critical - verify complete user-facing workflows end to end

tests should be added to the plan as tasks, and implemented as part of the feature development process.

### Build tasks as autonomous as possible
No human in the loop. You can ask/search for relevant CLIs or MCPs.
