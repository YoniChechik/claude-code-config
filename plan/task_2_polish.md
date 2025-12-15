# Task 2: Polish and Edge Cases

## Executive Summary

**What**: Harden the autocomplete system with edge case handling, visual polish, and robustness improvements.

**Why**: Task 1 delivers working autocomplete but doesn't handle terminal resize, long lists, empty states, or provide visual refinements. Production quality requires these.

**Approach**: Systematic pass through edge cases, adding guards and fallbacks. Visual improvements for better UX.

**Scope**: Edge cases, error handling, visual polish. No new major features.

**Current State**: After Task 1, basic autocomplete works but may break on edge cases.

**Target State**:
- Graceful handling of all edge cases
- Clean visual presentation
- No terminal corruption under any circumstances
- Feature flag for disable

**Steps**:
1. Terminal size awareness
2. Long list handling (pagination or truncation)
3. Empty/error states
4. Visual polish (colors, spacing)
5. Feature flag
6. Cleanup on SIGINT/SIGTERM

**Success Criteria**:
- Resize terminal during autocomplete - no corruption
- Commands dir empty - graceful message
- Very long command names - truncated cleanly
- Rapid typing - no flicker or lag
- `CC_AUTOCOMPLETE=0` disables feature

**Risk Level**: Low (hardening existing code)

**Difficulty**: Medium

---

## Implementation Phases

### Phase 1: Terminal Size Awareness (Medium)

**Problem**: Menu might overflow terminal height or width.

**Solution**:
```bash
get_terminal_size() {
    TERM_ROWS=$(tput lines)
    TERM_COLS=$(tput cols)
}

# Call before rendering menu
render_autocomplete_menu() {
    get_terminal_size

    local max_show=$((TERM_ROWS - 3))  # Leave room for prompt
    [[ $max_show -lt 1 ]] && max_show=1
    [[ $max_show -gt 10 ]] && max_show=10

    # Truncate long command names
    local max_width=$((TERM_COLS - 4))

    # ... rest of render with these limits
}
```

**Handle resize**:
```bash
trap 'get_terminal_size; render_autocomplete_menu ...' WINCH
```

But trapping WINCH inside a function is tricky. Simpler: just re-check size on each render.

---

### Phase 2: Long List Handling (Medium)

**Problem**: 20+ commands won't fit on screen.

**Options**:
1. **Truncate with indicator**: Show top 10 + "... and N more"
2. **Scrolling viewport**: Track scroll offset, show window
3. **Multi-column**: Display in columns

**Recommendation**: Option 1 for simplicity, upgrade to Option 2 if needed.

```bash
render_autocomplete_menu() {
    local -n items=$1
    local selected=$2
    local max_show=10

    local count=${#items[@]}

    # Scroll window to keep selection visible
    local scroll_offset=0
    if [[ $selected -ge $max_show ]]; then
        scroll_offset=$((selected - max_show + 1))
    fi

    printf '\033[s'

    for ((i=scroll_offset; i<scroll_offset+max_show && i<count; i++)); do
        printf '\n\033[K'
        local indicator=" "
        [[ $i -eq $selected ]] && indicator=">"
        printf '%s /%s' "$indicator" "${items[$i]}"
    done

    # Show scroll indicator if truncated
    if [[ $count -gt $max_show ]]; then
        printf '\n\033[K\033[90m  ... %d more\033[0m' $((count - max_show))
    fi

    printf '\033[u'
}
```

---

### Phase 3: Empty and Error States (Easy)

**Empty commands directory**:
```bash
run_autocomplete() {
    mapfile -t all_commands < <(get_slash_commands)

    if [[ ${#all_commands[@]} -eq 0 ]]; then
        printf "/\n"
        echo -e "\033[33mNo slash commands found in $CLAUDE_DIR/commands/\033[0m"
        AUTOCOMPLETE_RESULT=""
        return 1
    fi
    # ... continue
}
```

**No matches for filter**:
```bash
if [[ ${#filtered_commands[@]} -eq 0 ]]; then
    # Show "no matches" in menu area
    printf '\033[s\n\033[K\033[90m  (no matches)\033[0m\033[u'
fi
```

**Command file exists but is empty/invalid**: Not a concern - we just list filenames.

---

### Phase 4: Visual Polish (Easy)

**Improvements**:

1. **Colors**: Muted menu, highlighted selection
```bash
# Selection: bold cyan on dark background
printf '\033[1;36;44m /%s \033[0m' "${items[$i]}"

# Non-selected: dim
printf '\033[90m /%s\033[0m' "${items[$i]}"
```

2. **Prefix highlight**: Bold the matching part
```bash
local prefix="${input#/}"
local cmd="${items[$i]}"
local match="${cmd:0:${#prefix}}"
local rest="${cmd:${#prefix}}"
printf ' /\033[1m%s\033[0m%s' "$match" "$rest"
```

3. **Box drawing** (optional): Border around menu
```bash
printf '\n\033[K\u250c\u2500 Commands \u2500\u2500\u2500\u2510'
# ... items
printf '\n\033[K\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518'
```

Skip box drawing for v1 - adds complexity.

4. **Cursor hiding during render**:
```bash
printf '\033[?25l'  # Hide cursor
# ... render
printf '\033[?25h'  # Show cursor
```

Prevents flicker during updates.

---

### Phase 5: Feature Flag (Easy)

Allow disabling autocomplete for troubleshooting or preference.

```bash
# Near top of file, after CLAUDE_DIR setup
CC_AUTOCOMPLETE="${CC_AUTOCOMPLETE:-1}"

# In main loop
if [[ "$first_char" == "/" && "$CC_AUTOCOMPLETE" == "1" ]]; then
    # autocomplete mode
else
    # normal mode (also handles / when autocomplete disabled)
fi
```

Document: `CC_AUTOCOMPLETE=0 cc` to disable.

---

### Phase 6: Signal Handling and Cleanup (Medium)

**Problem**: Ctrl+C during autocomplete might leave terminal in bad state.

**Solution**:
```bash
# Cleanup function
autocomplete_cleanup() {
    printf '\033[?25h'  # Show cursor
    printf '\033[0m'    # Reset formatting
    # Clear any menu remnants
    clear_autocomplete_menu 15  # Max possible height
    stty sane 2>/dev/null       # Reset terminal
}

run_autocomplete() {
    trap 'autocomplete_cleanup; AUTOCOMPLETE_RESULT=""; return 1' INT TERM

    # ... main loop

    trap - INT TERM  # Reset trap before return
}
```

**Edge case**: Exit during autocomplete
```bash
# In main REPL loop
trap 'autocomplete_cleanup; exit 0' EXIT
```

---

### Phase 7: Performance (Easy)

**Potential issues**:
- Subshell for filtering is slow
- tput calls add latency

**Optimizations**:
```bash
# Cache commands list (only reload on explicit request)
CACHED_COMMANDS=()
COMMANDS_LOADED=false

get_slash_commands() {
    if [[ "$COMMANDS_LOADED" != "true" ]]; then
        CACHED_COMMANDS=()
        for f in "$CLAUDE_DIR"/commands/*.md; do
            [[ -f "$f" ]] && CACHED_COMMANDS+=("$(basename "$f" .md)")
        done
        COMMANDS_LOADED=true
    fi
    printf '%s\n' "${CACHED_COMMANDS[@]}"
}

# Inline filtering instead of subshell
filter_commands_inline() {
    local prefix="$1"
    FILTERED_COMMANDS=()
    for cmd in "${CACHED_COMMANDS[@]}"; do
        [[ "$cmd" == "$prefix"* ]] && FILTERED_COMMANDS+=("$cmd")
    done
}
```

---

## Testing Strategy

**Edge case tests**:
1. Resize terminal while menu is open
2. Empty commands directory
3. Single command in directory
4. Type filter that matches nothing
5. Type very long filter string
6. Rapid key presses
7. Ctrl+C at various points
8. Terminal with very few rows (< 5)

**Visual tests**:
1. Colors render correctly
2. No screen corruption after use
3. Cursor position correct after completion

**Feature flag tests**:
1. `CC_AUTOCOMPLETE=0 cc` - autocomplete disabled
2. `CC_AUTOCOMPLETE=1 cc` - autocomplete enabled (default)

---

## Dependencies

- Requires Task 1 complete

---

## Files Changed

Same file: `/home/yoni/.claude/_clones/fuzzy-matching/bin/cc`

**Estimated LOC**: 50-80 lines modified/added

---

## Definition of Done

- [ ] All edge cases handled without crashes
- [ ] Visual polish applied
- [ ] Feature flag works
- [ ] No terminal corruption under any test
- [ ] README updated with usage notes
