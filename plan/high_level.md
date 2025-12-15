# Interactive Slash Command Autocomplete for cc REPL

## Executive Summary

**What**: Add fish/zsh-style interactive autocomplete for slash commands in the `cc` REPL. When user types `/`, display all available commands below the prompt. As they type, filter and highlight matches in real-time. Arrow keys navigate, Enter selects.

**Approach**: Replace `read -r -e -p` with character-by-character input loop using `read -rsn1`. Use ANSI escape sequences to render completion menu below prompt. Capture arrow keys and Enter for navigation.

**Target State**: User types `/sy` and sees filtered list showing `/sync` highlighted. Arrow down to `/sync`, press Enter, command is submitted.

**Key Steps**:
1. Implement character-by-character input with key detection
2. Build completion menu rendering with ANSI cursor control
3. Add filtering logic (prefix match, then fuzzy fallback)
4. Integrate navigation (up/down/enter) and selection
5. Handle edge cases (resize, escape, backspace, long lists)

**Success Criteria**:
- Typing `/` shows all commands instantly
- Filtering updates as user types with no lag
- Arrow navigation works correctly
- Enter submits selected command
- Escape/Ctrl+C cancels and clears menu
- Normal non-slash input works unchanged

**Risk Level**: Medium - modifying core input loop

**Difficulty**: Hard

---

## Technical Approach Options

### Option A: Character-by-Character with read -rsn1 (RECOMMENDED)

**How**: Replace readline with raw character input loop. Build our own line buffer, handle each keypress manually, render completion UI with ANSI codes.

**Pros**:
- Full control over every keypress
- Can intercept arrow keys, render anything
- Pure bash, no dependencies

**Cons**:
- Lose readline features (history recall with up arrow, Ctrl+A/E, etc.)
- Must reimplement basic line editing
- More complex code

**Mitigation**: Only use this mode when `/` is detected. Fall back to readline for normal input.

### Option B: bind -x Key Binding

**How**: Use `bind -x '"/":autocomplete_function'` to trigger autocomplete when `/` is pressed.

**Pros**:
- Keeps readline for everything else
- Cleaner integration point

**Cons**:
- bind -x executes command but returns to readline
- Cannot maintain persistent completion menu during typing
- READLINE_LINE/READLINE_POINT only give snapshot, not continuous updates

**Verdict**: Does not support real-time filtering as user types.

### Option C: External Tool (fzf-style)

**How**: Pipe command list to a simple selector, capture output.

**Pros**:
- Simplest implementation
- Battle-tested UI

**Cons**:
- Violates "pure bash, no external deps" constraint
- Different UX (takes over terminal)

**Verdict**: Out of scope per requirements.

### Recommendation: Option A (Hybrid)

Use character-by-character input ONLY when autocomplete is active. For normal prompts, keep `read -e` for readline benefits. When user types `/` as first character, switch to autocomplete mode.

---

## Tasks Overview

| # | Task | Difficulty | Status |
|---|------|------------|--------|
| 1 | Core autocomplete engine | Hard | [ ] |
| 2 | Polish and edge cases | Medium | [ ] |

Two PRs recommended:
- PR1: Working autocomplete with basic functionality
- PR2: Edge cases, polish, and robustness

---

## Architecture

### Current Input Flow (line 218)
```
read -r -e -p "> " input
    -> whole line captured
    -> slash command check
    -> run_claude
```

### New Input Flow
```
show_prompt
read first char
if char == "/" then
    enter_autocomplete_mode()
        -> show all commands
        -> read char loop
        -> filter/render on each char
        -> arrow keys navigate
        -> enter returns selection
        -> escape cancels
else
    put char back, use readline for rest
```

### Key Components

**1. Command List Loader**
```bash
get_commands() {
    for f in "$CLAUDE_DIR"/commands/*.md; do
        basename "$f" .md
    done
}
```

**2. Character Input with Key Detection**
```bash
read -rsn1 char
case "$char" in
    $'\x1b')  # Escape sequence (arrows)
        read -rsn2 rest
        case "$rest" in
            '[A') handle_up ;;
            '[B') handle_down ;;
        esac ;;
    '')       handle_enter ;;    # Enter key
    $'\x7f')  handle_backspace ;; # Backspace
    *)        append_char "$char" ;;
esac
```

**3. Completion Menu Rendering**
```bash
render_menu() {
    local filtered=( $(filter_commands "$input") )
    # Save cursor, move down, print menu, restore cursor
    printf '\033[s'        # Save position
    printf '\033[%dB' 1    # Move down
    for i in "${!filtered[@]}"; do
        if [[ $i -eq $selected ]]; then
            printf '\033[7m%s\033[0m\n' "${filtered[$i]}"  # Inverted
        else
            printf '%s\n' "${filtered[$i]}"
        fi
    done
    printf '\033[u'        # Restore position
}
```

**4. Menu Cleanup**
```bash
clear_menu() {
    printf '\033[s'           # Save
    printf '\033[%dB' 1       # Move down
    for ((i=0; i<menu_height; i++)); do
        printf '\033[2K\n'    # Clear line
    done
    printf '\033[u'           # Restore
}
```

### State Variables
```bash
AUTOCOMPLETE_INPUT=""      # Current typed text (e.g., "/sy")
AUTOCOMPLETE_SELECTED=0    # Index of highlighted item
AUTOCOMPLETE_COMMANDS=()   # Filtered command list
AUTOCOMPLETE_ACTIVE=false  # Mode flag
```

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Terminal compatibility | Medium | High | Test on common terminals (gnome-terminal, iTerm2, WSL) |
| Readline feature loss | High | Medium | Only use raw mode during autocomplete; exit quickly |
| Performance on many commands | Low | Low | List is small (<20); no issue |
| Cursor position bugs | Medium | Medium | Careful save/restore; test resize handling |
| Conflict with existing keybindings | Low | Low | Minimal key capture during autocomplete only |

---

## Out of Scope

- Fuzzy matching in autocomplete (prefix match sufficient for v1)
- Multi-column display for long lists
- Tab completion (Enter only)
- Persistent history in autocomplete mode
- Mouse support

---

## Testing Strategy

1. **Manual tests**: Type `/`, verify menu appears; type `/sy`, verify filtering; arrow keys work; Enter selects; Escape cancels
2. **Edge cases**: Empty commands dir, single command, rapid typing, resize during menu
3. **Regression**: Normal (non-slash) input still works with readline
