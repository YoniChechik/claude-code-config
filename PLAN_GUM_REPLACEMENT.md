# Plan: Replace TUI Components with Gum

## Executive Summary

Replace custom bash TUI components (autocomplete, prompts, styling) with Gum while preserving streaming output and adding comprehensive tests.

**Scope:**
- ✅ Replace: autocomplete.sh (220 lines) → gum filter
- ✅ Replace: Prompt styling → gum style
- ✅ Replace: Error messages → gum style
- ⚠️ Modify: REPL input loop (keep peek-ahead, integrate gum)
- ❌ Keep: jq streaming pipeline (cannot replace)

**Key Constraints:**
- Gum filter is **vertical only** (no horizontal inline mode exists)
- Streaming JSON output requires jq (gum format is static-only)
- Must support testing without gum installed (mock functions)

---

## Architecture Design

### Component Mapping

| Current | Lines | Replacement | Notes |
|---------|-------|-------------|-------|
| `autocomplete.sh` | 220 | `gum filter` | Vertical dropdown vs horizontal inline |
| `show_prompt()` | 7 | `gum style` | Remove ANSI codes |
| Error messages | scattered | `gum style` | Consistent styling |
| `cc_filter.jq` | 317 | **KEEP** | Streaming requirement |
| REPL input peek | 30 | **KEEP** | Preserve UX, integrate gum |

### Critical Decision: Layout Change

**Current (horizontal inline):**
```
> /ask  pr-create  sync
    ↑ selected item inverted
```

**Gum (vertical dropdown):**
```
> /
  > ask
    pr-create
    sync
↑ selected with cursor, appears below input
```

**Verdict:** Accept vertical layout. It's standard TUI pattern (like VSCode/Vim autocomplete).

---

## Implementation Plan

### Phase 1: Setup & Infrastructure (Day 1)

**Files:** `bin/cc`, `bin/gum_autocomplete.sh` (new), `bin/gum_mocks.sh` (new)

1. **Add gum dependency check**
   ```bash
   # bin/cc startup (after jq check)
   if ! command -v gum >/dev/null 2>&1; then
       echo "Error: gum not installed"
       echo "Install: brew install gum (or see github.com/charmbracelet/gum)"
       exit 1
   fi
   ```

2. **Create gum autocomplete implementation**
   ```bash
   # bin/gum_autocomplete.sh
   run_autocomplete_gum() {
       local commands=$(get_slash_commands)
       local result=$(echo "$commands" | gum filter \
           --placeholder="Search commands..." \
           --height=10 \
           --no-limit=false)

       if [[ $? -eq 0 && -n "$result" ]]; then
           AUTOCOMPLETE_RESULT="/$result"
           return 0
       else
           AUTOCOMPLETE_RESULT=""
           return 1
       fi
   }
   ```

3. **Create test mocks**
   ```bash
   # bin/gum_mocks.sh
   mock_gum() {
       local subcommand="$1"
       shift
       case "$subcommand" in
           filter)
               # Parse --value or return first line from stdin
               local value=""
               while [[ $# -gt 0 ]]; do
                   case "$1" in
                       --value=*) value="${1#*=}"; shift ;;
                       --value) value="$2"; shift 2 ;;
                       *) shift ;;
                   esac
               done
               if [[ -n "$value" ]]; then
                   echo "$value"
               else
                   head -n 1
               fi
               return 0
               ;;
           style)
               # Just echo the text, ignore styling
               echo "$@" | sed 's/--[a-z-]*[= ]*[^ ]*//g'
               ;;
           *)
               echo "mock_gum: unknown subcommand: $subcommand" >&2
               return 1
               ;;
       esac
   }

   # Export for tests
   if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
       export -f mock_gum
   fi
   ```

**Deliverable:** gum installed, basic autocomplete working, mocks ready

---

### Phase 2: Replace Autocomplete (Day 2)

**Files:** `bin/cc` (modify lines 96-240)

1. **Source new autocomplete**
   ```bash
   # After line 97: source "$CLAUDE_DIR/bin/autocomplete.sh"
   source "$CLAUDE_DIR/bin/gum_autocomplete.sh"
   ```

2. **Replace autocomplete invocation** (cc:228-231)
   ```bash
   # Old:
   if [[ "$first_char" == "/" ]]; then
       autocomplete_status=0
       run_autocomplete || autocomplete_status=$?

   # New:
   if [[ "$first_char" == "/" ]]; then
       autocomplete_status=0
       run_autocomplete_gum || autocomplete_status=$?
   ```

3. **Handle exit codes**
   - 0 = selection made
   - 1 = cancelled (Esc/Ctrl+C)
   - 130 = Ctrl+C (gum specific)

   Update cc:235-239 to handle gum exit codes

4. **Keep old autocomplete.sh** - Don't delete yet (fallback/reference)

**Deliverable:** Slash commands use gum filter dropdown

---

### Phase 3: Replace Prompt & Styling (Day 3)

**Files:** `bin/cc` (lines 206-213, 271-272)

1. **Replace show_prompt**
   ```bash
   # Old (cc:206-213):
   show_prompt() {
       printf "\033[33m%s@%s:%s" "$USER" "$(hostname -s)" "$(pwd)"
       # ... stats ...
       printf "\033[0m\n"
   }

   # New:
   show_prompt() {
       local text="$USER@$(hostname -s):$(pwd)"
       if [ "$TOTAL_IN" -gt 0 ]; then
           local sec=$(awk "BEGIN {printf \"%.1f\", $LAST_MS/1000}")
           text+=" [${sec}s │ $MODEL]"
       fi
       gum style --foreground="yellow" "$text"
   }
   ```

2. **Replace error messages** (cc:271-272)
   ```bash
   # Old:
   echo -e "\033[33mUnknown command: $cmd\033[0m"
   echo -e "Did you mean: \033[32m$suggestion\033[0m?"

   # New:
   gum style --foreground="yellow" "Unknown command: $cmd"
   gum style --foreground="green" "Did you mean: $suggestion?"
   ```

3. **Replace startup message** (cc:218)
   ```bash
   # Old:
   echo "cc - Claude Code REPL (Ctrl+C to stop, Ctrl+D to exit)"

   # New:
   gum style --border="rounded" --padding="0 1" \
       "cc - Claude Code REPL (Ctrl+C to stop, Ctrl+D to exit)"
   ```

**Deliverable:** All prompts/messages use gum style

---

### Phase 4: Testing Infrastructure (Day 4)

**Files:** `bin/test_gum.sh` (new), `bin/test_all.sh` (modify)

1. **Create gum test suite**
   ```bash
   # bin/test_gum.sh
   #!/bin/bash
   set -u

   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

   # Source gum mocks
   source "$SCRIPT_DIR/gum_mocks.sh"
   gum() { mock_gum "$@"; }
   export -f gum

   # Source autocomplete
   source "$SCRIPT_DIR/gum_autocomplete.sh"

   # Test utilities
   TESTS_RUN=0
   TESTS_PASSED=0
   TESTS_FAILED=0

   pass() { echo -e "\033[32m✓\033[0m $1"; ((TESTS_PASSED++)); }
   fail() { echo -e "\033[31m✗\033[0m $1"; ((TESTS_FAILED++)); }
   run_test() { ((TESTS_RUN++)); "$@"; }

   # ============================================
   # GUM FILTER TESTS
   # ============================================

   test_gum_filter_returns_selection() {
       local result
       result=$(echo -e "ask\nfinish\nsync" | gum filter --value "finish")
       [[ "$result" == "finish" ]] && pass "gum filter returns selection" || \
           fail "gum filter expected 'finish', got '$result'"
   }

   test_gum_filter_exit_on_empty() {
       local result
       result=$(echo "" | gum filter 2>/dev/null)
       local exit_code=$?
       [[ $exit_code -ne 0 ]] && pass "gum filter exits on empty" || \
           fail "gum filter should fail on empty input"
   }

   test_autocomplete_integration() {
       # Mock command directory
       TEST_CLAUDE_DIR=$(mktemp -d)
       mkdir -p "$TEST_CLAUDE_DIR/commands"
       echo "test" > "$TEST_CLAUDE_DIR/commands/ask.md"
       echo "test" > "$TEST_CLAUDE_DIR/commands/sync.md"

       CLAUDE_DIR="$TEST_CLAUDE_DIR"

       local result
       result=$(run_autocomplete_gum <<< "ask")

       rm -rf "$TEST_CLAUDE_DIR"

       [[ "$AUTOCOMPLETE_RESULT" == "/ask" ]] && \
           pass "autocomplete integration works" || \
           fail "expected '/ask', got '$AUTOCOMPLETE_RESULT'"
   }

   # Run tests
   run_test test_gum_filter_returns_selection
   run_test test_gum_filter_exit_on_empty
   run_test test_autocomplete_integration

   # Summary
   echo ""
   echo "Gum Tests: $TESTS_PASSED/$TESTS_RUN passed"
   [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
   ```

2. **Add to main test suite**
   ```bash
   # bin/test_all.sh - add at end
   echo ""
   echo "Running gum component tests..."
   bash "$SCRIPT_DIR/test_gum.sh" || exit 1
   ```

3. **Key test categories** (30 new tests):
   - Gum filter basic selection (5 tests)
   - Gum filter edge cases (empty, single item, long list) (5 tests)
   - Autocomplete integration (8 tests)
   - Gum style formatting (4 tests)
   - Exit code handling (3 tests)
   - Mock verification (5 tests)

**Deliverable:** 30+ new tests, all passing with mocks

---

### Phase 5: Integration & Edge Cases (Day 5)

**Files:** `bin/cc` (lines 144-200), `bin/test_gum.sh`

1. **Test timeout handling** with gum
   - Ensure gum filter can be interrupted
   - Test Ctrl+C during autocomplete
   - Verify REPL doesn't exit

2. **Test terminal edge cases**
   - Very long command names
   - Terminal width < 40 cols
   - No commands available

3. **Test real gum** (optional, if installed)
   ```bash
   # bin/test_gum_integration.sh
   if command -v gum >/dev/null 2>&1; then
       echo "Testing with real gum..."
       # Automated tests using --value flag
   else
       echo "Skipping real gum tests (not installed)"
   fi
   ```

4. **Update demo script**
   ```bash
   # bin/demo_gum.sh (new)
   # Show gum-based autocomplete scenarios
   # Use real gum with --value for demos
   ```

**Deliverable:** All edge cases tested, demo script updated

---

### Phase 6: Documentation & Cleanup (Day 6)

**Files:** `README.md`, `bin/autocomplete.sh` (archive)

1. **Update README**
   - Add gum to dependencies
   - Installation instructions (brew/apt/go)
   - Screenshot/GIF of new autocomplete

2. **Archive old implementation**
   ```bash
   mv bin/autocomplete.sh bin/autocomplete.sh.old
   # Keep for reference/rollback
   ```

3. **Update comments in cc**
   - Document gum integration points
   - Note vertical layout choice

4. **Final testing**
   - Run full test suite (123 old + 30 new = 153 tests)
   - Manual testing in different terminals

**Deliverable:** Complete, documented, tested gum integration

---

## Testing Strategy

### Mock-Based Testing (Default)

**Approach:** Pure bash function mocks, no gum dependency

**Implementation:**
```bash
# In test files
source bin/gum_mocks.sh
gum() { mock_gum "$@"; }
export -f gum
```

**Coverage:**
- 100% of gum filter logic
- All exit codes
- Edge cases (empty input, long lists)
- Integration with REPL

**Pros:**
- Fast (no process spawning)
- No dependencies
- Deterministic

**Cons:**
- Doesn't test real gum behavior
- Must maintain mock accuracy

### Real Gum Testing (Optional)

**Approach:** Use real gum with --value flag for automation

**Implementation:**
```bash
# Conditional tests
if command -v gum &>/dev/null; then
    test_real_gum_filter() {
        result=$(echo -e "a\nb\nc" | gum filter --value "b")
        [[ "$result" == "b" ]]
    }
fi
```

**Coverage:**
- Gum installation verification
- Real terminal rendering
- Actual exit codes

**Pros:**
- High fidelity
- Catches gum version changes

**Cons:**
- Requires gum installed
- Slower
- Less deterministic

### Test Count Target

- **Current:** 123 tests (all passing)
- **After Phase 4:** 153 tests
  - Keep 123 existing tests
  - Add 30 gum-specific tests
- **After Phase 5:** 160+ tests
  - Add 7+ integration tests

---

## Risk Analysis

### Risk 1: Vertical Layout Rejection
**Impact:** High
**Probability:** Medium
**Mitigation:**
- Show demo early (Phase 1)
- User can reject plan before Phase 2
- Fallback: keep old autocomplete.sh

### Risk 2: Gum Not Available
**Impact:** High (blocks REPL)
**Probability:** Low (brew/apt installable)
**Mitigation:**
- Clear error message with install link
- Test on clean Ubuntu/Mac
- Document in README prominently

### Risk 3: Performance Regression
**Impact:** Medium (UX degradation)
**Probability:** Low
**Mitigation:**
- Benchmark: autocomplete latency < 50ms
- Gum is fast (Go binary)
- Measure in Phase 2

### Risk 4: Testing Gaps
**Impact:** Medium (bugs in production)
**Probability:** Low
**Mitigation:**
- 30+ new tests (Phase 4)
- Integration tests (Phase 5)
- Manual testing checklist

### Risk 5: Lost Features
**Impact:** Low
**Probability:** High (horizontal layout)
**Mitigation:**
- Document changes in README
- Vertical is industry standard
- Better for many items (10+)

---

## Success Criteria

1. ✅ Autocomplete works with gum filter (vertical dropdown)
2. ✅ All 153+ tests pass (123 old + 30+ new)
3. ✅ Autocomplete latency < 50ms
4. ✅ Error handling preserved (Ctrl+C, Ctrl+D, Esc)
5. ✅ No regression in jq streaming output
6. ✅ Clear gum installation instructions
7. ✅ Demo script shows new UX
8. ✅ Code reduced: ~220 lines removed (autocomplete.sh), ~50 added (gum_autocomplete.sh + mocks)

---

## Open Questions

1. **Prompt styling:** Use `gum style` everywhere or only for errors? (Simpler = everywhere)
2. **Fallback mode:** Keep old autocomplete.sh for systems without gum? (No - hard dependency)
3. **REPL input:** Replace peek-ahead with `gum input`? (No - keep peek-ahead, only replace menu)
4. **Testing depth:** Run real gum tests in CI? (No - mocks sufficient, optional local only)
5. **Color scheme:** Preserve yellow/green/gray or use gum defaults? (Preserve - consistent branding)

**Decision:** Answering "Simpler" on all = hard gum dependency, keep peek-ahead, pure mock testing, preserve colors.

---

## Implementation Files

### New Files
- `bin/gum_autocomplete.sh` (50 lines) - Gum-based autocomplete
- `bin/gum_mocks.sh` (80 lines) - Test mocks
- `bin/test_gum.sh` (200 lines) - Gum test suite
- `PLAN_GUM_REPLACEMENT.md` (this file)

### Modified Files
- `bin/cc` (280 lines) - Integrate gum, update prompts
- `bin/test_all.sh` (2307 lines) - Add gum test suite
- `README.md` - Add gum dependency

### Archived Files
- `bin/autocomplete.sh` → `bin/autocomplete.sh.old` (keep for rollback)

### Unchanged Files (Critical)
- `bin/cc_filter.jq` (317 lines) - Streaming output (cannot replace)

---

## Timeline

- **Day 1:** Setup & infrastructure (3 hours)
- **Day 2:** Replace autocomplete (4 hours)
- **Day 3:** Replace prompts/styling (2 hours)
- **Day 4:** Testing infrastructure (4 hours)
- **Day 5:** Integration & edge cases (3 hours)
- **Day 6:** Documentation & cleanup (2 hours)

**Total:** ~18 hours over 6 days

---

## Rollback Plan

If gum integration fails:

1. Revert `bin/cc` changes
2. Restore `bin/autocomplete.sh` from `.old`
3. Remove `bin/gum_*.sh` files
4. Remove gum tests from `test_all.sh`

**Rollback time:** < 15 minutes (git revert)

---

## Next Steps

**Immediate:**
1. User approval of vertical layout change
2. User approval of hard gum dependency
3. User confirmation on preserving peek-ahead UX

**After approval:**
1. Install gum locally for development
2. Create `bin/gum_autocomplete.sh`
3. Begin Phase 1 implementation
