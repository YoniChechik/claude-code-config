# Feature: Quality Skill File-Based Results

## TLDR
Refactor the quality skill so each review agent writes its findings to a file in a dedicated results directory. The fixer phase then reads each file and fixes issues one by one, providing better reliability and traceability.

## Research and References

The current quality skill (Phase 2) launches 6 agents in parallel via the Agent tool. Each agent returns its findings as part of its Agent tool response. The main orchestrator then must aggregate all 6 responses and fix everything in Phase 3. This is fragile because: (1) all findings live only in the conversation context, (2) there is no persistent artifact of what was found, (3) the fixer cannot iterate through a structured list.

The review skill already demonstrates the pattern of writing results to a file -- it writes a review.md report. We follow this same pattern: each quality agent writes its findings to a separate file in a quality-results/ directory. The fixer phase then reads each file, processes issues one by one, and can mark them as resolved.

The directory name should be quality-results/ in the current working directory. Each agent file should be named descriptively (e.g., 1-code-reuse.md, 2-code-quality.md, etc.). After the fixer completes, the directory serves as a record of what was found and fixed.

### Task 1: Create results directory setup in Phase 1
**What:**
- In skills/quality/SKILL.md, add a step at the end of Phase 1 (after identifying changes) that creates the quality-results/ directory in the current working directory
- Use rm -rf quality-results && mkdir quality-results to ensure a clean directory each run
- Add quality-results/ to the instructions so agents know the base path

### Task 2: Update each Phase 2 agent to write findings to a file
**What:**
- For each of the 6 agents in Phase 2, add an instruction that the agent MUST write its findings to a specific file:
  - Agent 1 writes to quality-results/1-code-reuse.md
  - Agent 2 writes to quality-results/2-code-quality.md
  - Agent 3 writes to quality-results/3-efficiency.md
  - Agent 4 writes to quality-results/4-slop-fail-fast.md
  - Agent 5 writes to quality-results/5-structure.md
  - Agent 6 writes to quality-results/6-test-integrity.md
- Each file should use a consistent format with Issue heading, File, Line, Severity, Description, Suggested fix
- If an agent finds NO issues, it should write a "No issues found" file
- The agent should STILL return a brief summary in its Agent response, but the file is the source of truth

### Task 3: Rewrite Phase 3 to read files and fix issues sequentially
**What:**
- Replace the current Phase 3 with a file-based approach
- New Phase 3 instructions:
  1. List all files in quality-results/ directory
  2. Read each file one by one (in order: 1-code-reuse.md through 6-test-integrity.md)
  3. For each file, parse each issue and fix it directly
  4. After fixing all issues from one file, move to the next file
  5. After all files are processed, summarize what was fixed
