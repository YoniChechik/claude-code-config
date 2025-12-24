# Task 1: Implement Inline Slash Command Autosuggest

## Executive Summary

**What**: Build inline autosuggest system for slash commands with grayout text, Tab cycling, and fuzzy matching - all in pure bash.

**Why**: Users need quick access to slash commands without breaking visual flow. Inline suggestions (like zsh-autosuggestions) provide discovery without interruption. Previous dropdown attempts were removed because they broke UX flow.

**Approach**: Create `autosuggest.sh` module with fuzzy matching and inline rendering. Use raw terminal mode for Tab key capture. Integrate into ccui.sh main loop. Test with real keystroke simulation (no mocks).

**Scope**:
- IN: Inline suggestion, Tab toggle, fuzzy match, integration tests
- OUT: Descriptions, multi-word completion, configuration, command arguments

**Current State**:
- `ccui.sh` uses bash readline: `read -r -e -p "> " input`
- No autosuggest capability
- Commands discovered from `~/.claude/commands/*.md`
- Previous autocomplete implementations removed (too complex or bad UX)

**Target State**:
- User types `/` → raw mode activates, all commands available
- User types `/ne` → sees `w-feature` in gray after cursor
- Tab → cycles to next match (`new-feature-short`)
- Enter/Space → accepts suggestion or current input
- Backspace past `/` → cancels, returns to normal mode
- Real integration tests validate behavior

**Steps**:
1. Create `bin/autosuggest.sh` with fuzzy matching (Easy)
2. Implement raw terminal input handler (Medium)
3. Add inline rendering with ANSI escape codes (Easy)
4. Integrate into ccui.sh main REPL loop (Easy)
5. Build integration test suite without mocks (Medium)

**Success Criteria**:
- Fuzzy match finds all substring matches, sorted by relevance
- Inline suggestion renders correctly (gray, no artifacts)
- Tab cycles through all matches, wraps to beginning
- Backspace, Enter, Ctrl+C, Ctrl+D all work correctly
- ≥10 integration tests pass in real CCUI environment
- Zero external dependencies

**Risk**: Medium - Raw terminal mode can have edge cases with different terminals

**Difficulty**: Medium

---

## Implementation Phases

### Phase 1: Fuzzy Matching Engine (Easy)

Create core matching logic for command filtering.

**Files**: `bin/autosuggest.sh` (new, ~50 lines)

**Functions**:
1. `get_slash_commands()` - Discover commands from directory
2. `fuzzy_score()` - Score a single match (lower = better)
3. `fuzzy_match()` - Filter and sort all matches

**Implementation**:

```bash
# Get available commands from directory
get_slash_commands() {
    local cmds=()
    for f in "$CLAUDE_DIR"/commands/*.md; do
        [[ -f "$f" ]] && cmds+=("$(basename "$f" .md)")
    done
    printf '%s\n' "${cmds[@]}" | sort
}

# Score a match (lower is better)
# 0 = exact match, 1 = prefix match, 100+pos = substring match
fuzzy_score() {
    local pattern="${1,,}"    # lowercase
    local candidate="${2,,}"  # lowercase

    [[ "$pattern" == "$candidate" ]] && { echo 0; return; }
    [[ "$candidate" == "$pattern"* ]] && { echo 1; return; }

    # Find position of pattern in candidate
    local before="${candidate%%$pattern*}"
    [[ "$before" != "$candidate" ]] && { echo $((100 + ${#before})); return; }

    # No match
    echo 999
}

# Get all matches sorted by score
fuzzy_match() {
    local pattern="$1"
    local cmd score

    while IFS= read -r cmd; do
        score=$(fuzzy_score "$pattern" "$cmd")
        [[ $score -lt 999 ]] && echo "$score $cmd"
    done < <(get_slash_commands) | sort -n | cut -d' ' -f2-
}
```

**Testing**: Unit test with known commands
- Empty pattern → all commands
- "ask" → exact match first
- "new" → both new-feature variants
- "pr" → all pr-* commands in order

**Difficulty**: Easy - Simple string matching algorithms

**Dependencies**: None (built-in bash string ops)

---

### Phase 2: Raw Terminal Input Handler (Medium)

Implement character-by-character input capture with key detection.

**Files**: `bin/autosuggest.sh` (add ~40 lines)

**Functions**:
1. `save_terminal_state()` - Store current tty settings
2. `restore_terminal_state()` - Restore on exit/error
3. `read_key()` - Read single character, detect special keys

**Implementation**:

```bash
# Terminal state management
SAVED_TTY=""

save_terminal_state() {
    SAVED_TTY=$(stty -g)
    stty -echo -icanon min 0 time 0
}

restore_terminal_state() {
    [[ -n "$SAVED_TTY" ]] && stty "$SAVED_TTY"
}

# Read single key, detect type
# Sets: KEY_TYPE (CHAR|TAB|ENTER|BACKSPACE|CTRL_C|CTRL_D|ESCAPE)
#       KEY_VALUE (for CHAR type)
read_key() {
    local char
    IFS= read -rsn1 char

    case "$char" in
        $'\t')        KEY_TYPE="TAB" ;;
        $'\n')        KEY_TYPE="ENTER" ;;
        $'\x7f'|$'\x08') KEY_TYPE="BACKSPACE" ;;
        $'\x03')      KEY_TYPE="CTRL_C" ;;
        $'\x04')      KEY_TYPE="CTRL_D" ;;
        $'\x1b')      KEY_TYPE="ESCAPE" ;;  # ESC key
        '')           KEY_TYPE="ENTER" ;;   # Some terminals
        *)            KEY_TYPE="CHAR"; KEY_VALUE="$char" ;;
    esac
}
```

**Error Handling**:
- Trap EXIT, INT, TERM to ensure restoration
- Test that Ctrl+C at any point restores terminal
- Verify terminal works after crashes

**Testing**:
- Send each key type, verify detection
- Test signal handling (kill, Ctrl+C)
- Ensure terminal restored on all paths

**Difficulty**: Medium - Requires careful signal handling

**Edge Cases**:
- Different terminal emulators encode keys differently
- Ctrl+C during read must clean up
- Nested raw mode (if ccui.sh already in raw mode)

---

### Phase 3: Inline Rendering (Easy)

Render suggestion in gray after cursor without artifacts.

**Files**: `bin/autosuggest.sh` (add ~30 lines)

**Functions**:
1. `render_inline()` - Show input + gray suggestion
2. `clear_line()` - Clear current line completely

**Implementation**:

```bash
# ANSI escape codes
C_GRAY='\033[90m'
C_RESET='\033[0m'

# Render input with inline suggestion
# Args: current_input, suggestion_text
render_inline() {
    local input="$1"
    local suggestion="$2"

    # Move to start of line, clear line
    printf '\r\033[K'

    # Print prompt + input
    printf '> %s' "$input"

    # Print suggestion in gray (if exists)
    if [[ -n "$suggestion" ]]; then
        # Only show the part after current input
        local remaining="${suggestion:${#input}}"
        printf "${C_GRAY}%s${C_RESET}" "$remaining"
    fi

    # Move cursor back to end of input (before suggestion)
    local backtrack=${#suggestion}
    backtrack=$((backtrack - ${#input}))
    [[ $backtrack -gt 0 ]] && printf '\033[%dD' "$backtrack"
}

# Clear entire line and redraw prompt
clear_line() {
    printf '\r\033[K> '
}
```

**Visual Testing**:
- Suggestion appears in gray
- Cursor positioned at end of user input (not suggestion)
- No flickering when updating
- Long suggestions don't wrap weirdly

**Difficulty**: Easy - Standard ANSI escape codes

**Considerations**:
- Terminal width - don't overflow
- Cursor must stay at correct position for typing
- Quick updates without flicker

---

### Phase 4: Main Input Loop with Suggestion State (Medium)

Orchestrate input handling, matching, and rendering.

**Files**: `bin/autosuggest.sh` (add ~80 lines)

**Functions**:
1. `read_with_autosuggest()` - Main entry point replacing bash readline

**State Machine**:
```
NORMAL mode: Regular input, no suggestion
  → User types '/' → SUGGEST mode

SUGGEST mode: Show inline suggestion
  → Tab: cycle through matches
  → Enter/Space: accept
  → Backspace past '/': exit to NORMAL
  → Regular char: update matches
```

**Implementation**:

```bash
# Main input function (replaces bash readline)
# Returns: Complete input string
# Exit codes: 0=success, 1=Ctrl+D, 2=Ctrl+C
read_with_autosuggest() {
    local input=""
    local matches=()
    local match_idx=0
    local suggest_mode=false

    # Setup terminal
    save_terminal_state
    trap 'restore_terminal_state' EXIT INT TERM

    # Initial render
    clear_line

    while true; do
        # Read one key
        read_key

        case "$KEY_TYPE" in
            CHAR)
                input="${input}${KEY_VALUE}"

                # Check if we just typed '/' at start or after space
                if [[ "$KEY_VALUE" == "/" ]] && [[ "$input" =~ ^/$ || "$input" =~ [[:space:]]/$ ]]; then
                    suggest_mode=true
                    mapfile -t matches < <(fuzzy_match "")
                    match_idx=0
                fi

                # Update matches if in suggest mode
                if [[ "$suggest_mode" == true ]]; then
                    # Extract pattern (everything after last /)
                    local pattern="${input##*/}"
                    mapfile -t matches < <(fuzzy_match "$pattern")
                    match_idx=0
                fi

                # Render
                local suggestion=""
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    suggestion="${base}${matches[$match_idx]}"
                fi
                render_inline "$input" "$suggestion"
                ;;

            TAB)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    # Cycle to next match
                    match_idx=$(( (match_idx + 1) % ${#matches[@]} ))

                    # Render with new suggestion
                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion"
                fi
                ;;

            ENTER)
                # Accept suggestion or current input
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    input="${base}${matches[$match_idx]}"
                fi

                restore_terminal_state
                echo ""  # newline
                echo "$input"
                return 0
                ;;

            BACKSPACE)
                if [[ -n "$input" ]]; then
                    input="${input:0:${#input}-1}"

                    # Exit suggest mode if we deleted the '/'
                    if [[ ! "$input" =~ / ]]; then
                        suggest_mode=false
                        matches=()
                    elif [[ "$suggest_mode" == true ]]; then
                        # Update matches
                        local pattern="${input##*/}"
                        mapfile -t matches < <(fuzzy_match "$pattern")
                        match_idx=0
                    fi

                    # Render
                    local suggestion=""
                    if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                        local base="${input%/*}/"
                        suggestion="${base}${matches[$match_idx]}"
                    fi
                    render_inline "$input" "$suggestion"
                fi
                ;;

            CTRL_C)
                restore_terminal_state
                echo "^C"
                return 2
                ;;

            CTRL_D)
                if [[ -z "$input" ]]; then
                    restore_terminal_state
                    echo ""
                    return 1
                fi
                ;;
        esac
    done
}
```

**State Transitions**:
- `/` typed → enter suggest mode, load all matches
- Char typed in suggest mode → update matches with fuzzy filter
- Tab in suggest mode → increment match_idx (circular)
- Backspace removes `/` → exit suggest mode
- Enter → accept suggestion (or input if no match)

**Difficulty**: Medium - Coordinating multiple states correctly

**Edge Cases**:
- Multiple `/` in input (only suggest after last one)
- No matches for pattern (show nothing)
- Cycling with 1 match (Tab does nothing)
- Very long input approaching terminal width

---

### Phase 5: Integration with ccui.sh (Easy)

Replace bash readline with autosuggest function.

**Files**: `bin/ccui.sh` (modify 5 lines)

**Changes**:

```bash
# Near top of file, after CLAUDE_DIR setup
source "$CLAUDE_DIR/bin/autosuggest.sh"

# In main loop (line ~146), replace:
# OLD:
read -r -e -p "> " input

# NEW:
input=$(read_with_autosuggest)
ret=$?
[[ $ret -eq 1 ]] && break     # Ctrl+D exits
[[ $ret -eq 2 ]] && continue  # Ctrl+C cancels
```

**Testing**:
- REPL starts correctly
- Autosuggest activates on `/`
- Commands execute properly after acceptance
- Error handling preserved

**Difficulty**: Easy - Simple function replacement

**Rollback Plan**: If autosuggest fails, catch error and fall back:
```bash
if ! source "$CLAUDE_DIR/bin/autosuggest.sh" 2>/dev/null; then
    read_with_autosuggest() { read -r -e -p "> " input; echo "$input"; }
fi
```

---

### Phase 6: Integration Testing Without Mocks (Medium)

Test actual behavior with keystroke simulation in real CCUI.

**Files**: `bin/test_autosuggest.sh` (new, ~150 lines)

**Test Strategy**: Use pseudo-terminal (PTY) to simulate user interaction

**Test Framework**:

```bash
#!/bin/bash
# test_autosuggest.sh - Integration tests for autosuggest

# Test helper: source autosuggest module
source "$(dirname "$0")/autosuggest.sh"

PASS=0
FAIL=0

test_pass() { echo "✓ $1"; ((PASS++)); }
test_fail() { echo "✗ $1"; ((FAIL++)); }

# Test 1: Fuzzy match - exact
test_fuzzy_exact() {
    local result=$(fuzzy_match "ask" | head -1)
    [[ "$result" == "ask" ]] && test_pass "Exact match" || test_fail "Exact match: got $result"
}

# Test 2: Fuzzy match - prefix
test_fuzzy_prefix() {
    local matches=$(fuzzy_match "new")
    local first=$(echo "$matches" | head -1)
    [[ "$first" == "new-feature" || "$first" == "new-feature-short" ]] && \
        test_pass "Prefix match" || test_fail "Prefix match: got $first"
}

# Test 3: Fuzzy match - substring
test_fuzzy_substring() {
    local matches=$(fuzzy_match "comment")
    echo "$matches" | grep -q "pr-comments" && \
        test_pass "Substring match" || test_fail "Substring match"
}

# Test 4: Fuzzy match - case insensitive
test_fuzzy_case() {
    local matches=$(fuzzy_match "ASK")
    echo "$matches" | grep -q "ask" && \
        test_pass "Case insensitive" || test_fail "Case insensitive"
}

# Test 5: Fuzzy match - no matches
test_fuzzy_empty() {
    local matches=$(fuzzy_match "zzzzzzz")
    [[ -z "$matches" ]] && test_pass "Empty result" || test_fail "Empty result"
}

# Test 6: Fuzzy match - empty pattern
test_fuzzy_all() {
    local matches=$(fuzzy_match "")
    local count=$(echo "$matches" | wc -l)
    [[ $count -ge 5 ]] && test_pass "All commands" || test_fail "All commands: got $count"
}

# Test 7: Score ordering - exact < prefix < substring
test_score_ordering() {
    local s1=$(fuzzy_score "ask" "ask")
    local s2=$(fuzzy_score "ask" "ask-me")
    local s3=$(fuzzy_score "ask" "please-ask")

    [[ $s1 -eq 0 && $s2 -eq 1 && $s3 -gt 100 ]] && \
        test_pass "Score ordering" || test_fail "Score ordering: $s1 $s2 $s3"
}

# Test 8: Terminal state save/restore
test_terminal_state() {
    local before=$(stty -g)
    save_terminal_state
    local during=$(stty -g)
    restore_terminal_state
    local after=$(stty -g)

    [[ "$before" == "$after" && "$before" != "$during" ]] && \
        test_pass "Terminal state" || test_fail "Terminal state"
}

# Test 9: Key detection - Tab
test_key_tab() {
    # Simulate Tab keystroke
    (echo -en '\t' | {
        read_key
        [[ "$KEY_TYPE" == "TAB" ]]
    }) && test_pass "Tab detection" || test_fail "Tab detection"
}

# Test 10: Key detection - Backspace
test_key_backspace() {
    # Simulate backspace
    (echo -en '\x7f' | {
        read_key
        [[ "$KEY_TYPE" == "BACKSPACE" ]]
    }) && test_pass "Backspace detection" || test_fail "Backspace detection"
}

# Test 11: End-to-end with simulated input
test_e2e_simple() {
    # This would use expect/empty for full PTY simulation
    # Simplified version: test that function exists and has right signature
    declare -f read_with_autosuggest >/dev/null && \
        test_pass "Function exists" || test_fail "Function exists"
}

# Run all tests
echo "Running autosuggest tests..."
echo ""

test_fuzzy_exact
test_fuzzy_prefix
test_fuzzy_substring
test_fuzzy_case
test_fuzzy_empty
test_fuzzy_all
test_score_ordering
test_terminal_state
test_key_tab
test_key_backspace
test_e2e_simple

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
```

**Additional E2E Tests** (requires `expect` or manual testing):
1. Type `/ne` → verify `w-feature` appears in gray
2. Press Tab → verify cycles to `w-feature-short`
3. Press Tab again → verify wraps to `w-feature`
4. Press Enter → verify command accepted
5. Type `/xyz` → verify no suggestion (no match)
6. Type `/` then backspace → verify returns to normal mode

**Test Execution**:
```bash
# Unit tests (no PTY needed)
bash bin/test_autosuggest.sh

# Manual E2E test (inside actual CCUI)
bin/ccui.sh
# Try typing slash commands interactively
```

**Difficulty**: Medium - PTY simulation is tricky, but unit tests cover most logic

**Coverage**:
- Fuzzy matching: 7 tests (exact, prefix, substring, case, empty, all, scoring)
- Terminal handling: 1 test (state save/restore)
- Key detection: 2 tests (Tab, Backspace)
- E2E: 1 integration test (manual or with expect)

---

## Testing Strategy

### Unit Tests (No CCUI Required)

Test individual functions in isolation:

1. **Fuzzy matching** - All match types, scoring, sorting
2. **Terminal state** - Save/restore works
3. **Key detection** - All key types recognized

**Run**: `bash bin/test_autosuggest.sh`

### Integration Tests (Inside CCUI)

Test actual user workflows:

1. **Basic suggestion** - Type `/as`, see `k` in gray
2. **Tab cycling** - Multiple matches, wrap around
3. **Acceptance** - Enter commits suggestion
4. **Cancellation** - Backspace exits suggest mode
5. **Edge cases** - No matches, long input, fast typing

**Run**: Manual testing in `bin/ccui.sh` or with `expect` script

### Test Commands Setup

Create test commands for consistent testing:

```bash
# Already exist in repo
commands/ask.md
commands/new-feature.md
commands/new-feature-short.md
commands/pr-comments.md
commands/pr-create.md
...
```

Use existing commands - no test fixtures needed.

---

## Dependencies

**None** - Pure bash with standard Unix tools:
- `bash` ≥4.0 (associative arrays, modern string ops)
- `stty` (POSIX standard, terminal control)
- `printf` (bash built-in, ANSI codes)
- `read` (bash built-in, character input)

All tools available on any modern Unix (Linux, macOS, BSD).

---

## Performance Considerations

### Fuzzy Matching
- **Complexity**: O(n × m) where n=commands, m=pattern length
- **Typical**: 10 commands × 10 chars = 100 ops
- **Benchmark**: <1ms on modern systems
- **Optimization**: Not needed

### Rendering
- **ANSI escape codes**: Instant (terminal hardware rendering)
- **Cursor positioning**: <1ms round-trip to terminal
- **Flicker prevention**: Single `printf` per render
- **Optimization**: Already optimal

### Terminal Mode Switching
- **Raw mode entry**: ~1ms (one stty call)
- **Per-keystroke overhead**: None (already in raw mode)
- **Exit overhead**: ~1ms (restore stty)
- **Optimization**: Not needed

**Expected UX**: Imperceptible lag (<50ms) between keystroke and suggestion update.

---

## Error Handling

### Terminal Restoration

**Problem**: If script crashes in raw mode, terminal becomes unusable.

**Solution**:
```bash
trap 'restore_terminal_state' EXIT INT TERM
```

Handles:
- Normal exit
- Ctrl+C interrupt
- Kill signal
- Script errors

### Graceful Degradation

**Problem**: Autosuggest might fail on exotic terminals.

**Solution**:
```bash
# In ccui.sh integration
if ! source "$CLAUDE_DIR/bin/autosuggest.sh" 2>/dev/null; then
    # Fall back to simple readline
    read_with_autosuggest() {
        local input
        read -r -e -p "> " input
        echo "$input"
    }
fi
```

### Command Directory Missing

**Problem**: `~/.claude/commands/` doesn't exist.

**Solution**:
```bash
get_slash_commands() {
    [[ ! -d "$CLAUDE_DIR/commands" ]] && return
    # ... rest of function
}
```

Returns empty list → no suggestions → graceful.

---

## Rollback Plan

If autosuggest causes issues, easy rollback:

1. **Remove source line** from `ccui.sh`:
   ```bash
   # Comment out or delete
   # source "$CLAUDE_DIR/bin/autosuggest.sh"
   ```

2. **Restore original readline**:
   ```bash
   read -r -e -p "> " input
   ```

3. **Delete module**:
   ```bash
   rm bin/autosuggest.sh
   ```

**Downtime**: Zero - one-line change reverts behavior.

---

## Acceptance Criteria

### Functional Requirements

- [ ] Fuzzy match finds all substring matches (case-insensitive)
- [ ] Matches sorted by relevance (exact > prefix > substring)
- [ ] Inline suggestion appears in gray after cursor
- [ ] Tab cycles through all matches, wraps to start
- [ ] Enter accepts current suggestion or typed input
- [ ] Space accepts suggestion (treated like Enter)
- [ ] Backspace past `/` exits suggest mode
- [ ] Ctrl+C cancels input, returns to prompt
- [ ] Ctrl+D on empty input exits REPL
- [ ] Multiple `/` in input (e.g., `/ask /new`) suggests after last one

### Non-Functional Requirements

- [ ] Response time: <50ms from keystroke to render
- [ ] No visual artifacts (flicker, cursor jumps, leftover text)
- [ ] Terminal restored correctly on all exit paths
- [ ] Works on common terminals (xterm, gnome-terminal, iTerm2, macOS Terminal)
- [ ] Zero external dependencies (pure bash)

### Testing Requirements

- [ ] ≥10 unit tests passing (fuzzy match, terminal, keys)
- [ ] ≥5 integration tests passing (actual CCUI usage)
- [ ] All tests run without mocks (real environment)
- [ ] Test suite runs in <5 seconds

### Code Quality

- [ ] Module is <250 lines total
- [ ] Functions are <50 lines each
- [ ] No global state except SAVED_TTY
- [ ] All functions have clear comments
- [ ] Error handling for all edge cases

---

## Success Metrics

**User Experience**:
- Typing `/` immediately shows all available commands (first match)
- Typing more chars refines suggestion in real-time
- Tab feels natural for cycling (like shell completion)
- No learning curve - behavior is intuitive

**Technical**:
- Zero reported bugs related to terminal state corruption
- Performance imperceptible on systems with <100 commands
- Test suite catches regressions (run before commits)

**Adoption**:
- Feature ships enabled by default
- No configuration needed
- No user complaints about UX flow interruption

---

## Timeline Estimate

- **Phase 1**: Fuzzy matching - 1 hour
- **Phase 2**: Terminal input - 2 hours
- **Phase 3**: Inline rendering - 1 hour
- **Phase 4**: Main loop - 3 hours
- **Phase 5**: Integration - 0.5 hours
- **Phase 6**: Testing - 2 hours

**Total**: ~10 hours of development time

**Actual**: Single PR, can be completed in one session.

---

## Risk Assessment

### High Confidence Areas
- Fuzzy matching (straightforward algorithm)
- ANSI rendering (well-documented escape codes)
- Integration point (simple function replacement)

### Medium Confidence Areas
- Terminal state handling (need thorough signal testing)
- Key detection (varies by terminal emulator)
- Performance (should be fine, but needs validation)

### Mitigation Strategies
- Extensive testing on multiple terminals
- Graceful fallback if sourcing fails
- Trap-based cleanup for terminal restoration
- Performance benchmarks before shipping

---

## Open Questions

**Q: Should Space accept suggestion or insert space?**
**A**: Accept suggestion. Slash commands don't have spaces in names, so space = completion. User can press Space to accept and continue typing.

**Q: What if terminal width < suggestion length?**
**A**: Truncate suggestion at terminal edge. Don't wrap to next line (breaks inline visual).

**Q: Should we show match count (e.g., "1/3")?**
**A**: No - adds visual clutter. Single suggestion is simple mental model.

**Q: What about command arguments (e.g., `/ask "my question"`)?**
**A**: Out of scope. Only suggest command name, not arguments.

**Q: Should we highlight matched substring in suggestion?**
**A**: No - adds complexity. Inline gray is sufficient for v1.

---

## Future Improvements (Post-MVP)

1. **Command descriptions**: Show one-line description below suggestion
2. **Usage frequency**: Sort by most-used commands first
3. **Substring highlighting**: Bold the matched part in suggestion
4. **Multi-word**: Suggest in middle of line (after spaces)
5. **Configuration**: Disable via env var, customize colors
6. **Argument suggestions**: Autocomplete common arguments

All out of scope for Task 1.
