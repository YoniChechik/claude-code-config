# Feature Planning

Creates a comprehensive plan for a feature with codebase analysis and architectural design.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation 
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description of the feature you want to implement."

## Process

### Step 1: Feature Description Analysis
Parse the feature description:
- Extract core requirements and scope
- Identify any additional planning commands mentioned
- Validate description completeness

### Step 2: Codebase Analysis  
Use Task tool with multiple parallel invocations to understand current codebase:
- **Architecture patterns**: Search existing similar features/components
- **Integration points**: Identify APIs, databases, interfaces to connect with
- **Dependencies**: Find relevant utilities, libraries, and frameworks already in use
- **Test patterns**: Understand current testing approaches and frameworks

### Step 3: Flow-Based Planning

ULTRATHINK and create comprehensive `plan.md`. The plan should be verbose and state all needed blocks and tests. Use these sections in file:

**Architecture Design**:
- Component breakdown aligned with existing patterns
- Data flow and integration points
- API/interface definitions

**Development steps**:
- Each step should be small, focused, and result in a single meaningful commit.
- Each step should try to build a complete working part as small as possible
- Don't number steps and substeps, put `[ ]` before each step title so we can track completion.
- Add unit tests for all blocks and e2e tests if needed.

### Step 4: Get Approval
Present the plan for user approval or modification requests before implementation begins.