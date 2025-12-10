# Dropdown Slash Command Completion

Enhanced slash command chooser for Claude Code REPL with dropdown-style interface.

## Features

1. **Dropdown Display**: All fuzzy matches appear BELOW the input line (not inline)
2. **Auto-trigger**: Completion activates automatically when you type `/`
3. **Arrow Navigation**: Use Up/Down arrows to navigate through matches
4. **Visual Highlighting**: Selected match has reverse video background (`\033[7m`)
5. **Fuzzy Matching**: Commands filtered as you type (from `slash_complete.sh`)
6. **Scrolling**: Shows max 10 items with scroll indicator for more
7. **Multiple Accept Methods**: Tab or Enter to accept selection
8. **Escape to Cancel**: ESC key hides dropdown and keeps current input

## File Structure

- `/home/yoni/.claude/bin/cc_readline.sh` - Main dropdown implementation
- `/home/yoni/.claude/bin/slash_complete.sh` - Fuzzy matching engine (unchanged)
- `/home/yoni/.claude/bin/cc` - REPL (integrated with dropdown)
- `/home/yoni/.claude/bin/test_dropdown.sh` - Standalone test script
- `/home/yoni/.claude/bin/validate_dropdown.sh` - Validation checks

## Key Functions

### `render_dropdown(matches_array_name, selected_index, max_display)`
Renders the dropdown menu below the cursor:
- Takes matches array by name reference
- Highlights the selected item with reverse video
- Shows scroll indicator if more than max_display items
- Returns number of lines rendered

### `clear_dropdown(line_count)`
Clears N lines below the cursor:
- Saves cursor position
- Moves down and clears each line
- Restores cursor to original position

### `read_with_completion()`
Main input loop with dropdown support:
- Returns completed command string
- Exit codes: 0 = success, 1 = Ctrl+D, 2 = Ctrl+C

## Keyboard Controls

| Key | Action |
|-----|--------|
| `/` | Auto-trigger completion |
| Up Arrow | Select previous match |
| Down Arrow | Select next match |
| Tab | Accept current selection |
| Enter | Accept current selection |
| Escape | Cancel dropdown, keep input |
| Backspace | Delete char, update matches |
| Ctrl+D | Exit REPL |
| Ctrl+C | Cancel current input |

## ANSI Escape Codes Used

| Code | Purpose |
|------|---------|
| `\033[7m` | Reverse video (highlight background) |
| `\033[0m` | Reset all styles |
| `\033[K` | Clear to end of line |
| `\033[s` | Save cursor position |
| `\033[u` | Restore cursor position |
| `\033[90m` | Dim gray (for scroll indicator) |

## Testing

### Standalone Test
```bash
/home/yoni/.claude/bin/test_dropdown.sh
```
Type `/` to see all commands, type characters to filter.

### Validation
```bash
/home/yoni/.claude/bin/validate_dropdown.sh
```
Runs 10+ checks to verify implementation.

### Live Test (in REPL)
```bash
cc
```
Then type `/` and test navigation.

## Implementation Details

### Auto-trigger Logic
```bash
if [ "$char" = "/" ] && { [ -z "${input%/}" ] || [[ "${input%/}" == *[[:space:]] ]]; }; then
    # Trigger on "/" at start or after whitespace
    mapfile -t matches < <(get_matches "")
    dropdown_lines=$(render_dropdown matches "$match_idx")
fi
```

### Arrow Key Detection
```bash
case "$seq" in
    '[A')  # Up arrow - previous match
        clear_dropdown "$dropdown_lines"
        match_idx=$(((match_idx - 1 + ${#matches[@]}) % ${#matches[@]}))
        dropdown_lines=$(render_dropdown matches "$match_idx")
        ;;
    '[B')  # Down arrow - next match
        clear_dropdown "$dropdown_lines"
        match_idx=$(((match_idx + 1) % ${#matches[@]}))
        dropdown_lines=$(render_dropdown matches "$match_idx")
        ;;
esac
```

### Dropdown Cleanup Pattern
Every state change follows this pattern:
1. Clear old dropdown: `clear_dropdown "$dropdown_lines"`
2. Update state (index, matches, input)
3. Render new dropdown: `dropdown_lines=$(render_dropdown ...)`

## Integration with cc REPL

The main `cc` script sources `cc_readline.sh` and replaces bash's built-in `read`:

```bash
# Before (using bash readline)
read -r -e -p "> " input || break

# After (using dropdown completion)
input=$(read_with_completion)
ret=$?
[ $ret -eq 1 ] && break  # Ctrl+D
[ $ret -eq 2 ] && continue  # Ctrl+C
```

## Future Enhancements

Potential improvements:
- Command descriptions in dropdown
- Multi-column layout for many matches
- Custom highlighting colors
- Configurable max_display count
- Mouse support
