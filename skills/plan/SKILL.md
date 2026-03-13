---
name: "plan"
description: "Enter plan mode, explore codebase, create structured plan, then exit with clear-context dialog"
argument-hint: "[feature-description]"
---

# Plan Mode

Use the built-in `EnterPlanMode` tool to enter plan mode, then explore and plan.

## Feature description from user input
"$ARGUMENTS"

## Process

### Step 1: Enter Plan Mode
Call the `EnterPlanMode` tool to activate read-only plan mode.

### Step 2: Explore & Plan
While in plan mode:
- Explore existing code patterns and architecture
- Identify related files and components
- Understand dependencies and integration points
- Use web search to find relevant information and examples

### Step 3: Ask Questions

**Ask the user (use AskUserQuestion):**
- Unclear scope or boundaries
- Multiple valid technical approaches
- Breaking changes or migration needed
- Concerns and tradeoffs

**Decide yourself:**
- Implementation details, file/function names, code organization, other obvious choices

### Step 4: Write Plan File

Determine feature name from branch: `FEATURE_NAME=$(git rev-parse --abbrev-ref HEAD)`

Create `plan_$FEATURE_NAME.md` with this structure:

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

### Testing Requirements - CRITICAL

**EVERY FEATURE MUST INCLUDE TESTS. Features must be verified, not assumed to work.**

Follow the testing goblet (inverted pyramid):
- **Unit tests + mocks**: Foundation layer, test individual functions and classes in isolation
- **Integration tests**: The bulk of tests - verify components work together, test real interactions between modules
- **E2E tests**: Few but critical - verify complete user-facing workflows end to end

### Build tasks as autonomous as possible
No human in the loop. You can ask/search for relevant CLIs or MCPs.

### Step 5: Exit Plan Mode
Call the `ExitPlanMode` tool with the plan content. This triggers the interactive approval dialog where the user can choose to clear context before implementation.
