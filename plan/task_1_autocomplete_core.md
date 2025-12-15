# Task 1: Core Autocomplete Engine

## Executive Summary

**What**: Implement the core interactive autocomplete system for slash commands in cc REPL.

**Why**: Current UX requires user to type full command and only suggests corrections after errors. Modern shells show completions proactively, reducing errors and improving discoverability.

**Approach**: Hybrid input system - detect `/` as first character, switch to character-by-character mode with ANSI-rendered menu. Arrow keys navigate, Enter selects. Normal input uses readline unchanged.

**Scope**: Core functionality only - menu display, filtering, navigation, selection. Edge case handling deferred to Task 2.

**Current State**:
- Line 218: `read -r -e -p "> " input` captures whole line
- Lines 224-235: Post-hoc slash command validation with fuzzy suggestion
- No proactive completion

**Target State**:
- `/` triggers completion menu immediately
- Menu updates as user types filter text
- Up/Down arrows navigate selection
- Enter submits selected command
- Works for the happy path; edge cases addressed in Task 2

**Steps**:
1. Add command list loader function
2. Implement key detection with escape sequence parsing
3. Build menu rendering with ANSI codes
4. Create filtering logic
5. Integrate into main REPL loop
6. Test basic flow

**Success Criteria**:
- Type `/` -> see all commands below prompt
- Type `/sy` -> see only matching commands
- Up/Down -> selection moves
- Enter -> command submitted to claude
- Normal input (no `/`) works exactly as before

**Risk Level**: Medium

**Difficulty**: Hard

---

## Implementation Phases

### Phase 1: Command List and Utilities (Easy)

Add helper functions before the main loop.

**Functions to add:**

```bash
# Get list of available slash commands
get_slash_commands() {
    local cmds=()
    for f in "$CLAUDE_DIR"/commands/*.md; do
        [[ -f "$f" ]] && cmds+=("$(basename "$f" .md)")
    done
    printf '%s\n' "${cmds[@]}" | sort
}

# Filter commands by prefix
filter_commands() {
    local prefix="$1"
    local cmd
    while IFS= read -r cmd; do
        [[ "$cmd" == "$prefix"* ]] && echo "$cmd"
    done
}
```

**Files changed**: `/home/yoni/.claude/_clones/fuzzy-matching/bin/cc`

**Lines affected**: Add after line 93 (after `find_similar_command` function)

---

### Phase 2: Key Detection Engine (Medium)

Implement character-by-character input with escape sequence detection.

**Key insight**: Arrow keys send escape sequences:
- Up: `\x1b[A`
- Down: `\x1b[B`
- Left: `\x1b[D`
- Right: `\x1b[C`

```bash
# Read a single key (handles escape sequences)
# Sets KEY_CHAR and KEY_TYPE
read_key() {
    KEY_CHAR=""
    KEY_TYPE=""

    IFS= read -rsn1 char

    case "$char" in
        $'\x1b')  # Escape - could be sequence or just Esc
            read -rsn1 -t 0.01 next
            if [[ -n "$next" ]]; then
                read -rsn1 -t 0.01 code
                case "$next$code" in
                    '[A') KEY_TYPE="UP" ;;
                    '[B') KEY_TYPE="DOWN" ;;
                    '[C') KEY_TYPE="RIGHT" ;;
                    '[D') KEY_TYPE="LEFT" ;;
                    *)    KEY_TYPE="ESCAPE" ;;
                esac
            else
                KEY_TYPE="ESCAPE"
            fi
            ;;
        '')       KEY_TYPE="ENTER" ;;
        $'\x7f'|$'\x08')  KEY_TYPE="BACKSPACE" ;;
        $'\x03')  KEY_TYPE="CTRL_C" ;;
        *)        KEY_TYPE="CHAR"; KEY_CHAR="$char" ;;
    esac
}
```

**Critical detail**: The `-t 0.01` timeout distinguishes standalone Escape from arrow key sequences.

---

### Phase 3: Menu Rendering (Medium)

ANSI escape code based menu display below current prompt line.

**Core escape sequences needed**:
- `\033[s` - Save cursor position
- `\033[u` - Restore cursor position
- `\033[K` - Clear to end of line
- `\033[nB` - Move cursor down n lines
- `\033[7m` - Inverse video (highlight)
- `\033[0m` - Reset formatting

```bash
# Render completion menu below current line
render_autocomplete_menu() {
    local -n items=$1      # Array of items to show
    local selected=$2      # Currently selected index
    local max_show=10      # Max items to display

    local count=${#items[@]}
    [[ $count -eq 0 ]] && return

    # Limit display
    local show=$((count < max_show ? count : max_show))

    printf '\033[s'        # Save cursor

    for ((i=0; i<show; i++)); do
        printf '\n\033[K'  # Newline, clear line
        if [[ $i -eq $selected ]]; then
            printf '\033[7m /%s \033[0m' "${items[$i]}"
        else
            printf ' /%s' "${items[$i]}"
        fi
    done

    printf '\033[u'        # Restore cursor
}

# Clear the menu area
clear_autocomplete_menu() {
    local height=$1

    printf '\033[s'        # Save cursor
    for ((i=0; i<height; i++)); do
        printf '\n\033[K'  # Newline, clear line
    done
    printf '\033[u'        # Restore cursor
}
```

**Important**: Menu height must be tracked to clear correctly on update/exit.

---

### Phase 4: Autocomplete Mode Loop (Hard)

The main autocomplete interaction loop.

```bash
# Run autocomplete mode, return selected command or empty
run_autocomplete() {
    local input="/"
    local selected=0
    local all_commands
    local filtered_commands

    # Load commands
    mapfile -t all_commands < <(get_slash_commands)
    filtered_commands=("${all_commands[@]}")

    # Initial render
    printf "/"
    render_autocomplete_menu filtered_commands $selected

    while true; do
        read_key

        case "$KEY_TYPE" in
            CHAR)
                input+="$KEY_CHAR"
                printf "%s" "$KEY_CHAR"
                # Re-filter
                local prefix="${input#/}"
                mapfile -t filtered_commands < <(
                    printf '%s\n' "${all_commands[@]}" | filter_commands "$prefix"
                )
                selected=0
                clear_autocomplete_menu ${#all_commands[@]}
                render_autocomplete_menu filtered_commands $selected
                ;;

            BACKSPACE)
                if [[ ${#input} -gt 1 ]]; then
                    input="${input%?}"
                    printf '\b \b'  # Erase char
                    # Re-filter
                    local prefix="${input#/}"
                    mapfile -t filtered_commands < <(
                        printf '%s\n' "${all_commands[@]}" | filter_commands "$prefix"
                    )
                    selected=0
                    clear_autocomplete_menu ${#all_commands[@]}
                    render_autocomplete_menu filtered_commands $selected
                fi
                ;;

            UP)
                if [[ $selected -gt 0 ]]; then
                    ((selected--))
                    clear_autocomplete_menu ${#filtered_commands[@]}
                    render_autocomplete_menu filtered_commands $selected
                fi
                ;;

            DOWN)
                if [[ $selected -lt $((${#filtered_commands[@]} - 1)) ]]; then
                    ((selected++))
                    clear_autocomplete_menu ${#filtered_commands[@]}
                    render_autocomplete_menu filtered_commands $selected
                fi
                ;;

            ENTER)
                clear_autocomplete_menu ${#filtered_commands[@]}
                if [[ ${#filtered_commands[@]} -gt 0 ]]; then
                    echo  # Newline after input
                    AUTOCOMPLETE_RESULT="/${filtered_commands[$selected]}"
                else
                    echo
                    AUTOCOMPLETE_RESULT="$input"
                fi
                return 0
                ;;

            ESCAPE|CTRL_C)
                clear_autocomplete_menu ${#filtered_commands[@]}
                printf '\r\033[K'  # Clear line
                AUTOCOMPLETE_RESULT=""
                return 1
                ;;
        esac
    done
}
```

---

### Phase 5: REPL Integration (Medium)

Modify the main loop to use autocomplete when appropriate.

**Current loop** (lines 216-238):
```bash
while true; do
    show_prompt
    read -r -e -p "> " input || break
    ...
```

**New loop structure**:
```bash
while true; do
    show_prompt

    # Peek at first character
    printf "> "
    IFS= read -rsn1 first_char

    if [[ "$first_char" == "/" ]]; then
        # Autocomplete mode
        if run_autocomplete; then
            input="$AUTOCOMPLETE_RESULT"
        else
            continue  # Cancelled
        fi
    elif [[ -z "$first_char" ]]; then
        echo
        continue  # Empty enter
    else
        # Normal readline mode - put char back and use read -e
        # Note: Can't truly "unget" in bash, so we read rest of line
        printf "%s" "$first_char"
        IFS= read -r -e rest
        input="${first_char}${rest}"
        echo  # Newline
    fi

    [[ -z "$input" ]] && continue
    [[ "$input" =~ ^(exit|quit)$ ]] && break
    history -s "$input"

    # ... rest of loop unchanged
```

**Tricky part**: When first char is not `/`, we've consumed it. We print it back and read the rest. This works but loses some readline features for that first character.

**Alternative**: Always use autocomplete mode and implement full line editing. More work but cleaner.

---

### Phase 6: Basic Testing (Easy)

Manual test checklist:

1. Start cc, type `/` - verify all commands appear
2. Type `sy` - verify only `sync` shows
3. Press Down - verify selection moves
4. Press Up - verify selection moves back
5. Press Enter - verify command executes
6. Press Escape - verify menu clears, prompt resets
7. Type `hello world` (no slash) - verify normal input works
8. Press Ctrl+D - verify REPL exits

---

## Testing Strategy

**Unit-ish tests** (can be done in bash):
- `get_slash_commands` returns expected list
- `filter_commands` correctly filters by prefix
- `read_key` correctly identifies arrow keys, enter, backspace

**Integration tests**:
- Full flow with expect or manual testing
- Verify no terminal corruption after exit

**Regression**:
- Normal prompts work
- History still works
- Fuzzy suggestion for bad commands still works

---

## Dependencies

- None for Task 1
- Task 2 depends on this

---

## Files Changed

Single file: `/home/yoni/.claude/_clones/fuzzy-matching/bin/cc`

**Estimated LOC**: 150-200 lines added

**Sections affected**:
- New section after fuzzy matching (lines ~94): Autocomplete functions
- Main loop (lines 216-238): Modified input handling

---

## Rollback Plan

If autocomplete causes issues:
1. Feature flag: `CC_AUTOCOMPLETE=0 cc` disables it
2. Easy revert: All new code is additive, can be removed cleanly
