# Slash Command Autosuggest Feature

## Executive Summary

**What**: Add inline autosuggest for slash commands in CCUI (like zsh-autosuggestions) with Tab toggle and fuzzy matching.

**Why**: Currently users must remember/type full slash command names. Inline suggestions improve UX by showing what's available as they type, without interrupting flow with dropdowns.

**Approach**: Inline grayout suggestion after cursor using ANSI escape codes, triggered on `/` prefix. Tab cycles through fuzzy matches. Pure bash implementation with real integration tests (no mocks).

**Target State**:
- User types `/ne` → sees `/new-feature` in gray after cursor
- Tab cycles through matches (`/new-feature` → `/new-feature-short`)
- Tab again accepts, or just continue typing
- Single suggestion shown at a time (no dropdown/menu)
- Works for all commands in `~/.claude/commands/*.md`

**Key Steps**:
1. Implement fuzzy match algorithm for command filtering
2. Add inline rendering with ANSI escape codes (gray suggestion)
3. Integrate raw terminal mode input handling with Tab key support
4. Write integration tests that run inside actual CCUI session

**Success Criteria**:
- Fuzzy match finds commands with substring anywhere in name
- Inline suggestion appears in gray after cursor
- Tab cycles through matches, Enter/space accepts
- Backspace past `/` cancels suggestion mode
- All tests pass without mocks (test in real CCUI environment)
- Zero external dependencies (no gum, pure bash)

**Risk Level**: Medium (terminal manipulation can have edge cases)

**Difficulty**: Medium

---

## Tasks Overview

- [x] Task 0: Planning and codebase exploration
- [ ] Task 1: Implement inline autosuggest with fuzzy matching *(single PR, ~150 LOC)*

---

## Architecture

### Current State

**CCUI Structure** (`bin/ccui.sh`):
- Main REPL loop reads user input with bash `read -r -e -p "> " input`
- Uses bash readline (`-e` flag) for basic editing
- Slash commands dispatched by matching input pattern against `commands/*.md` files
- Output streamed through `jq` filter (`cc_filter.jq`) for formatting

**Command Discovery**:
- Commands stored as markdown files in `~/.claude/commands/`
- Filename (without `.md`) is the command name
- Examples: `ask.md` → `/ask`, `new-feature.md` → `/new-feature`

**Previous Attempts** (all removed):
1. **Dropdown menu** (commit c851162, removed a380387): Multi-item dropdown below input - UX wasn't good, interrupted flow
2. **gum integration** (commit 64d414e, removed 94946a4): External dependency, harder to test
3. **Full autocomplete module** (commit 94946a4, removed 3790e56): 220 lines, complex terminal handling with edge cases

**Why Previous Approaches Failed**:
- Dropdown: Broke visual flow, required arrow navigation
- gum: External dependency, not inline
- Full autocomplete: Over-engineered, had wrapping/scrolling bugs

### Proposed Architecture

**Design Philosophy**:
- **Inline only**: Suggestion appears after cursor, not in separate UI element
- **Single suggestion**: Show one match at a time, Tab to cycle (simple mental model)
- **Raw mode input**: Custom key handling without bash readline to capture Tab
- **Stateless rendering**: Each keystroke recalculates and re-renders

**Components**:

1. **Command Discovery** (`get_slash_commands()`)
   - Lists all `.md` files in commands directory
   - Returns sorted command names

2. **Fuzzy Matcher** (`fuzzy_match()`)
   - Input: pattern (what user typed), candidate (command name)
   - Algorithm: Case-insensitive substring match with scoring
   - Score: 0 = exact match, 1 = prefix match, 100+pos = substring match
   - Returns: Sorted array of matches by score

3. **Input Handler** (`read_with_autosuggest()`)
   - Replaces `read -r -e -p "> " input` in main REPL
   - Raw terminal mode (`stty -echo -icanon`)
   - Captures individual keystrokes
   - Detects `/` at start/after space to trigger suggest mode
   - Handles: regular chars, backspace, Tab, Enter, Ctrl+C, Ctrl+D

4. **Inline Renderer** (`render_inline_suggestion()`)
   - Shows grayed-out suggestion after current input
   - ANSI codes: `\033[90m` (gray text), `\033[0m` (reset)
   - Cursor positioning: `\r` (return to line start), `\033[K` (clear to EOL)
   - Renders: `> /ne\033[90mw-feature\033[0m` then move cursor back

5. **Integration Point**:
   - Replace line 146 in `ccui.sh`: `read -r -e -p "> " input`
   - With: `input=$(read_with_autosuggest)` + exit code handling

**Terminal Control Flow**:
```
User types '/'
  → Enter raw mode
  → Get all commands
  → Show first match inline (gray)

User types more chars
  → Update fuzzy matches
  → Show new first match inline

User presses Tab
  → Cycle to next match
  → Re-render inline

User presses Enter/Space
  → Accept current suggestion (or typed input)
  → Exit raw mode
  → Return complete command

User backspaces past '/'
  → Clear suggestion
  → Exit raw mode
  → Return to normal input
```

**File Structure**:
```
bin/
  ccui.sh          - Main REPL (modify input handling)
  autosuggest.sh   - New module with all autosuggest logic

plan/
  high_level.md    - This file
  task_1_autosuggest.md - Detailed implementation plan
```

**Testing Strategy**:
- NO mocks - test inside actual CCUI
- Integration test script that simulates keystrokes
- Test cases: fuzzy matching, Tab cycling, backspace, edge cases
- Use pseudo-terminal (script/expect) for keystroke simulation

---

## Risks & Mitigations

### Risk 1: Terminal Edge Cases (Medium)
**Issue**: Raw terminal mode + cursor positioning can break with:
- Terminal window resizing
- Very long input wrapping
- Different terminal emulators

**Mitigation**:
- Keep it simple - only inline suggestion, no multi-line rendering
- Test on common terminals (xterm, gnome-terminal, iTerm2)
- Graceful degradation - on error, fall back to no suggestion

### Risk 2: Input Lag (Low)
**Issue**: Recalculating fuzzy matches on every keystroke could feel slow with many commands

**Mitigation**:
- Fuzzy match is O(n*m) where n=commands (~10), m=pattern length (~20)
- Benchmark shows <1ms even with 100 commands
- No optimization needed for typical use case

### Risk 3: Conflicting Key Bindings (Low)
**Issue**: Tab key might conflict with shell/readline bindings

**Mitigation**:
- Raw mode disables all readline bindings
- Clean restoration with `stty -g` save/restore
- Trap signals (INT, TERM) to ensure cleanup

---

## Dependencies

**None** - Pure bash implementation with built-in tools:
- `stty` - Terminal control (standard on all Unix)
- `printf` - ANSI escape codes (bash built-in)
- `read` - Character-by-character input (bash built-in)

---

## Backward Compatibility

**N/A** - This is a new feature, no existing behavior to break.

Existing REPL input handling replaced entirely, but:
- Return values compatible (string output)
- Exit codes preserved (0=success, 1=Ctrl+D, 2=Ctrl+C)
- Error handling: Falls back to simple readline on failure

---

## Success Metrics

1. **Functional**:
   - Fuzzy match accuracy: 100% for substring matches
   - Tab cycling works for all match counts (1, 2, 10+)
   - Backspace/cancel works correctly
   - No visual artifacts (cursor in right place)

2. **Testing**:
   - ≥10 integration test cases passing
   - Test coverage: matching, rendering, input handling, edge cases
   - All tests run in real CCUI (no mocks)

3. **UX**:
   - Suggestion appears <50ms after keystroke (imperceptible)
   - Inline rendering doesn't flicker
   - Intuitive - no documentation needed to understand

---

## Future Enhancements (Out of Scope)

- Multi-word completion (suggest after spaces in middle of line)
- Command descriptions shown below suggestion
- Usage frequency scoring (suggest most-used commands first)
- Highlight matching substring in suggestion
- Configuration options (disable, change colors, max matches)
