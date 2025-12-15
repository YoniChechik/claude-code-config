# Fuzzy Matching for Claude Code CLI

## Executive Summary

**What**: Add fuzzy matching to the `cc` CLI wrapper for command suggestions when users mistype slash commands.

**Approach**: Pure bash implementation using Levenshtein distance (via `awk`) to suggest similar commands when an unknown command is entered.

**Target State**: When user types `/snc` (typo), CLI suggests "Did you mean: /sync?"

**Key Steps**:
1. Implement fuzzy match function in bash
2. Integrate into `cc` REPL loop for command not found cases
3. Show top suggestion(s) to user

**Success Criteria**: Typing a close-enough misspelling suggests the correct command.

**Risk Level**: Low - additive feature, doesn't break existing functionality

**Difficulty**: Easy

---

## Assumptions

1. Fuzzy matching is for **slash commands** (not file search) - most immediate value
2. Commands list is small (<20), so O(n) comparison is fine
3. Using pure bash/awk - no external dependencies like `fzf`
4. Threshold: suggest if edit distance <= 3 or <= 40% of command length

---

## Tasks Overview

| # | Task | Difficulty | Status |
|---|------|------------|--------|
| 1 | Add fuzzy match slash command suggestions | Easy | [ ] |

Single PR - feature is small and self-contained (~50-80 LOC).

---

## Architecture

### Current Flow
```
User input -> cc REPL -> claude --prompt "input"
```

### New Flow (for unknown commands)
```
User input "/snc" -> detect unknown command -> fuzzy match against commands/ -> suggest "/sync"
```

### Key Integration Point
- `/home/yoni/.claude/bin/cc` line 181: `run_claude "$input"`
- Add check before `run_claude` for slash commands that don't exist

### Fuzzy Match Implementation
- Levenshtein distance in awk (no external deps)
- Scan `commands/*.md` for available commands
- Return closest match if within threshold

---

## Risks

| Risk | Mitigation |
|------|------------|
| Performance on large command sets | Commands dir is small; not a real concern |
| False positives | Use reasonable threshold (edit distance <= 3) |

---

## Out of Scope (Future)

- File path fuzzy matching
- Interactive selection (fzf-style)
- Learning from user corrections
