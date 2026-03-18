---
name: "quality"
description: "Run quality checks, fix code quality issues, check code style, format code, or perform lint checks"
---

# Quality: Code Review, Cleanup, and Formatting

Review all changed files for quality issues. Fix any issues found.

## Phase 1: Identify Changes
Run `git diff` (or `git diff HEAD` if there are staged changes) to see what changed. If there are no git changes, review the most recently modified files that the user mentioned or that you edited earlier in this conversation.

Then create a clean results directory for the review agents:
```bash
rm -rf quality-results && mkdir quality-results
```

## Phase 2: Launch Review Agents in Parallel
Use the Agent tool to launch all agents concurrently in a single message. Pass each agent the full diff so it has the complete context.

**CRITICAL SCOPE RULE:** All review agents must ONLY flag issues in code that was added or modified compared to what we branched out from. Never flag, remove, or suggest changes to pre-existing code that was not touched by the current changes. If pre-existing code has issues, it is out of scope.

**RESULTS OUTPUT:** Each agent MUST write its findings to a file in the `quality-results/` directory. Use the Write tool to create the file. If no issues are found, write "No issues found." to the file. The file is the source of truth — the agent's return message is just a brief summary.

**File format for each agent's results file:**
```markdown
# [Category] Findings

## Issue 1: [Short description]
**File:** path/to/file
**Line:** 42
**Severity:** HIGH/MEDIUM/LOW
**Description:** What is wrong and why
**Suggested fix:** How to fix it

## Issue 2: ...
```

### Agent 1: Code Reuse Review
**Output file:** `quality-results/1-code-reuse.md`
For each change:
1. **Search for existing utilities and helpers** that could replace newly written code. Look for similar patterns elsewhere in the codebase — common locations are utility directories, shared modules, and files adjacent to the changed ones.
2. **Flag any new function that duplicates existing functionality.** Suggest the existing function to use instead.
3. **Flag any inline logic that could use an existing utility** — hand-rolled string manipulation, manual path handling, custom environment checks, ad-hoc type guards, and similar patterns are common candidates.

### Agent 2: Code Quality Review
**Output file:** `quality-results/2-code-quality.md`
Review the same changes for hacky patterns:
1. **Redundant state**: state that duplicates existing state, cached values that could be derived, observers/effects that could be direct calls
2. **Parameter sprawl**: adding new parameters to a function instead of generalizing or restructuring existing ones
3. **Copy-paste with slight variation**: near-duplicate code blocks that should be unified with a shared abstraction
4. **Leaky abstractions**: exposing internal details that should be encapsulated, or breaking existing abstraction boundaries
5. **Stringly-typed code**: using raw strings where constants, enums (string unions), or branded types already exist in the codebase

### Agent 3: Efficiency Review
**Output file:** `quality-results/3-efficiency.md`
Review the same changes for efficiency:
1. **Unnecessary work**: redundant computations, repeated file reads, duplicate network/API calls, N+1 patterns
2. **Missed concurrency**: independent operations run sequentially when they could run in parallel
3. **Hot-path bloat**: new blocking work added to startup or per-request/per-render hot paths
4. **Recurring no-op updates**: state/store updates inside polling loops, intervals, or event handlers that fire unconditionally — add a change-detection guard so downstream consumers aren't notified when nothing changed
5. **Unnecessary existence checks**: pre-checking file/resource existence before operating (TOCTOU anti-pattern) — operate directly and handle the error
6. **Memory**: unbounded data structures, missing cleanup, event listener leaks
7. **Overly broad operations**: reading entire files when only a portion is needed, loading all items when filtering for one

### Agent 4: Slop & Fail-Fast Review
**Output file:** `quality-results/4-slop-fail-fast.md`
Review the same changes for AI-generated slop and fail-fast violations:

**AI Slop to remove:**
**Scope reminder:** Only remove slop that was introduced in the current branch compared to what we branched out from. Do not touch pre-existing comments, docstrings, or patterns.
- Self-explanatory comments
- Commented-out code
- Debug prints
- Docstrings (function names should be self-explanatory)
- Over-engineered error handling

**Fail-Fast Violations (language-agnostic):**
- Checking if attributes/keys exist before accessing them → Access directly and let it fail
- Using fallback defaults when accessing collections → Fail on missing items
- Unnecessary type checks for expected types → Just call the method and let it fail
- Checking collection size before accessing elements → Just access and let it fail
- Catch-log-continue pattern → hides failures
- Silent failure catches → never do this
- Sentinel values → Never return -1, null, or empty string to indicate errors, raise exceptions instead

**Python-specific fail-fast patterns:**
- `hasattr()` / `getattr()` → Use direct attribute access: `obj.attr`
- `dict.get(key, default)` → Use `dict[key]` to fail on missing keys
- `dict.pop(key, default)` → Use `dict.pop(key)` to fail on missing keys
- `isinstance()` checks for expected types → just call the method (legitimate uses for polymorphism/validation are OK)
- `if len(items) > 0: items[0]` → Just access `items[0]`
- `value = x or default` → Hides falsy values, use explicit None check if needed
- `try: ... except: pass` → Ultimate silent failure, never do this

### Agent 5: Structure Review
**Output file:** `quality-results/5-structure.md`
Review the same changes for proper code organization:

**Code should be "Top to Bottom"** — organized from most important/general to least important/specific:
1. Constants (public, then private)
2. Public classes
3. Main/public functions
4. Private classes
5. Private functions

**Rules:**
- No relative imports (use absolute imports)
- Python: All private items MUST start with `_` prefix

## Phase 3: Fix Issues
Wait for all five agents to complete, then aggregate and fix all issues:

1. Read ALL result files from `quality-results/` directory (`1-code-reuse.md` through `5-structure.md`). If any expected file is missing, note it and proceed with available files.
2. **Aggregate & deduplicate**: Collect all issues from all files into a single list. Remove duplicates — if multiple agents flagged the same code location or the same problem, keep only one entry.
3. **Print the consolidated list**: Output the full deduplicated issue list so the user can see everything that was found before fixes begin.
4. **Fix each issue one by one**:
   - Work through the list sequentially
   - Fix each issue directly in the codebase
   - If a fix changes code referenced by a later issue, re-read the affected file to find the updated location. Skip issues already resolved by an earlier fix.
5. After all issues are fixed, briefly summarize what was fixed

## Phase 4: Lint & Format
After all code fixes are applied, run the quality check script to auto-format and lint:
```bash
~/.claude/scripts/quality_check.sh --fix
```
Then verify no errors remain:
```bash
~/.claude/scripts/quality_check.sh
```
If errors remain, read the files and fix manually, then re-run until clean.

When done, summarize ALL that was fixed.

Finally, clean up the results directory:
```bash
rm -rf quality-results
```
