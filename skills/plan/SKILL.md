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
- No human in the loop. You can ask/search for relevant CLIs or MCPs.
- Testing Requirements - CRITICAL:
  - **EVERY FEATURE MUST INCLUDE TESTS. Features must be verified, not assumed to work.**
  - **Tests are written and reviewed in a separate /test phase after implementation. The plan should describe WHAT to test per task, but the /test skill handles HOW.**
  - Each task in the plan should consider what needs testing -- include a brief note on what to test for that task (behaviors, edge cases, integration points). Do NOT include a full testing strategy; that is the /test skill's responsibility.
  - **Testing philosophy -- integration-first, anti-mocking:**
    - **Integration tests** are the bulk -- wire real components together and verify they work as a system
    - **Unit tests** should be mock-free where possible -- call real code, use real data structures
    - **E2E tests**: Few but critical -- verify complete user-facing workflows end to end
  - **Anti-mocking rules:**
    - NEVER mock the code under test
    - NEVER mock simple/pure functions -- just call them
    - NEVER mock data structures, models, or value objects
    - NEVER mock to avoid setup -- invest in proper test fixtures and factories instead
    - ONLY mock: external services (APIs, databases, network), time/randomness, slow/flaky third-party libs
    - If you need more than 2 mocks in a test, rethink the test design

### Step 3: Add Tasks to Task List
Add the tasks from the plan file to the task list in the relevant positions. Tasks should be added in the order they should be executed, but can be worked on in parallel if they are independent

