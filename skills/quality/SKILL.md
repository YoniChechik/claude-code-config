---
name: "quality"
description: "Run quality checks, fix code quality issues, check code style, format code, or perform lint checks"
---

# Quality: Code Review, Cleanup, and Formatting

Review all changed files for quality issues. Fix any issues found.

## Phase 1: Identify Changes
Run `git diff` (or `git diff HEAD` if there are staged changes) to see what changed. If there are no git changes, review the most recently modified files that the user mentioned or that you edited earlier in this conversation.

## Phase 2: Launch Five Review Agents in Parallel
Use the Agent tool to launch all five agents concurrently in a single message. Pass each agent the full diff so it has the complete context.

### Agent 1: Code Reuse Review
For each change:
1. **Search for existing utilities and helpers** that could replace newly written code. Look for similar patterns elsewhere in the codebase — common locations are utility directories, shared modules, and files adjacent to the changed ones.
2. **Flag any new function that duplicates existing functionality.** Suggest the existing function to use instead.
3. **Flag any inline logic that could use an existing utility** — hand-rolled string manipulation, manual path handling, custom environment checks, ad-hoc type guards, and similar patterns are common candidates.

### Agent 2: Code Quality Review
Review the same changes for hacky patterns:
1. **Redundant state**: state that duplicates existing state, cached values that could be derived, observers/effects that could be direct calls
2. **Parameter sprawl**: adding new parameters to a function instead of generalizing or restructuring existing ones
3. **Copy-paste with slight variation**: near-duplicate code blocks that should be unified with a shared abstraction
4. **Leaky abstractions**: exposing internal details that should be encapsulated, or breaking existing abstraction boundaries
5. **Stringly-typed code**: using raw strings where constants, enums (string unions), or branded types already exist in the codebase

### Agent 3: Efficiency Review
Review the same changes for efficiency:
1. **Unnecessary work**: redundant computations, repeated file reads, duplicate network/API calls, N+1 patterns
2. **Missed concurrency**: independent operations run sequentially when they could run in parallel
3. **Hot-path bloat**: new blocking work added to startup or per-request/per-render hot paths
4. **Recurring no-op updates**: state/store updates inside polling loops, intervals, or event handlers that fire unconditionally — add a change-detection guard so downstream consumers aren't notified when nothing changed
5. **Unnecessary existence checks**: pre-checking file/resource existence before operating (TOCTOU anti-pattern) — operate directly and handle the error
6. **Memory**: unbounded data structures, missing cleanup, event listener leaks
7. **Overly broad operations**: reading entire files when only a portion is needed, loading all items when filtering for one

### Agent 4: Slop & Fail-Fast Review
Review the same changes for AI-generated slop and fail-fast violations:

**AI Slop to remove:**
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
Wait for all five agents to complete. Aggregate their findings and fix each issue directly. If a finding is a false positive or not worth addressing, note it and move on — do not argue with the finding, just skip it.

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

When done, briefly summarize what was fixed (or confirm the code was already clean).
