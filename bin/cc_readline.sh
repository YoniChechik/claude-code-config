#!/bin/bash

# cc_readline.sh - Custom readline input with dropdown slash completion

source "${CLAUDE_DIR:-$HOME/.claude}/bin/slash_complete.sh"

# ============================================================
# DROPDOWN RENDERING
# ============================================================

# Clear N lines below cursor
clear_dropdown() {
    local n="$1"
    [ "$n" -le 0 ] && return

    # Save cursor position, clear lines below, restore cursor
    printf '\033[s'  # Save cursor position
    for ((i=0; i<n; i++)); do
        printf '\n\033[K'  # Move down and clear line
    done
    printf '\033[u'  # Restore cursor position
}

# Render dropdown menu below input line
render_dropdown() {
    local matches_ref="$1[@]"
    local matches=("${!matches_ref}")
    local match_idx="$2"
    local max_display="${3:-10}"

    local n="${#matches[@]}"
    [ "$n" -eq 0 ] && return 0

    # Limit displayed items
    local display_count=$((n < max_display ? n : max_display))

    # Calculate start index for scrolling
    local start_idx=0
    if [ "$n" -gt "$max_display" ]; then
        start_idx=$(((match_idx / max_display) * max_display))
        # Ensure we don't go past the end
        [ $((start_idx + max_display)) -gt "$n" ] && start_idx=$((n - max_display))
    fi

    # Save cursor, move to next line
    printf '\033[s\n'

    # Render each visible match
    for ((i=0; i<display_count; i++)); do
        local idx=$((start_idx + i))
        local cmd="${matches[$idx]}"

        if [ "$idx" -eq "$match_idx" ]; then
            # Highlighted item (reverse video)
            printf '\033[7m  /%s\033[0m\033[K\n' "$cmd"
        else
            # Normal item
            printf '  /%s\033[K\n' "$cmd"
        fi
    done

    # Show scroll indicator if needed
    if [ "$n" -gt "$max_display" ]; then
        local end_idx=$((start_idx + display_count - 1))
        printf '\033[90m  [%d-%d of %d]\033[0m\033[K\n' $((start_idx + 1)) $((end_idx + 1)) "$n"
        display_count=$((display_count + 1))
    fi

    # Restore cursor position
    printf '\033[u'

    echo "$display_count"
}

# ============================================================
# CUSTOM INPUT WITH DROPDOWN COMPLETION
# ============================================================

# Read input with dropdown slash completion support
read_with_completion() {
    local input=""
    local matches=()
    local match_idx=0
    local dropdown_lines=0

    # Save terminal state
    local saved_stty=$(stty -g)

    # Setup terminal for raw input
    stty -echo -icanon time 0 min 0

    # Restore on exit
    trap 'stty "$saved_stty"' EXIT INT TERM

    printf "> "

    while true; do
        # Read one character
        local char
        IFS= read -r -n1 char

        # Handle special keys
        case "$char" in
            $'\x04')  # Ctrl+D
                if [ -z "$input" ]; then
                    clear_dropdown "$dropdown_lines"
                    stty "$saved_stty"
                    echo ""
                    return 1
                fi
                ;;
            $'\x03')  # Ctrl+C
                clear_dropdown "$dropdown_lines"
                stty "$saved_stty"
                echo "^C"
                return 2
                ;;
            $'\x7f')  # Backspace
                if [ -n "$input" ]; then
                    # Clear old dropdown
                    clear_dropdown "$dropdown_lines"
                    dropdown_lines=0

                    # Remove last character
                    input="${input:0:${#input}-1}"

                    # Clear line and redraw
                    printf '\r\033[K> %s' "$input"

                    # Update matches
                    if [[ "$input" == /* ]]; then
                        local pattern="${input:1}"
                        mapfile -t matches < <(get_matches "$pattern")
                        match_idx=0

                        # Show dropdown if we have matches
                        if [ "${#matches[@]}" -gt 0 ]; then
                            dropdown_lines=$(render_dropdown matches "$match_idx")
                        fi
                    else
                        matches=()
                    fi
                elif [[ "$input" == "/" ]]; then
                    # Backspace on just "/" - clear everything
                    clear_dropdown "$dropdown_lines"
                    dropdown_lines=0
                    input=""
                    matches=()
                    printf '\r\033[K> '
                fi
                ;;
            $'\n')  # Enter
                clear_dropdown "$dropdown_lines"

                # Accept selected match if in completion mode
                if [[ "$input" == /* ]] && [ "${#matches[@]}" -gt 0 ]; then
                    input="/${matches[$match_idx]}"
                fi

                stty "$saved_stty"
                echo ""
                echo "$input"
                return 0
                ;;
            $'\t')  # Tab - accept current selection
                if [[ "$input" == /* ]] && [ "${#matches[@]}" -gt 0 ]; then
                    clear_dropdown "$dropdown_lines"
                    dropdown_lines=0

                    input="/${matches[$match_idx]}"
                    matches=()

                    # Clear and redraw
                    printf '\r\033[K> %s' "$input"
                fi
                ;;
            $'\x1b')  # Escape sequence (arrow keys)
                # Read next two characters
                local seq
                IFS= read -r -n2 -t 0.01 seq

                if [[ "$input" == /* ]] && [ "${#matches[@]}" -gt 0 ]; then
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
                        '')  # Escape alone - cancel completion
                            if [ "${#matches[@]}" -gt 0 ]; then
                                clear_dropdown "$dropdown_lines"
                                dropdown_lines=0
                                matches=()
                                # Keep the input as-is
                            fi
                            ;;
                    esac
                fi
                ;;
            *)
                # Regular character
                if [[ "$char" =~ [[:print:]] ]]; then
                    # Clear old dropdown first
                    clear_dropdown "$dropdown_lines"
                    dropdown_lines=0

                    input="$input$char"

                    # Clear and redraw input
                    printf '\r\033[K> %s' "$input"

                    # Check if we're in slash completion mode
                    if [ "$char" = "/" ] && { [ -z "${input%/}" ] || [[ "${input%/}" == *[[:space:]] ]]; }; then
                        # Just typed /, start completion
                        mapfile -t matches < <(get_matches "")
                        match_idx=0

                        if [ "${#matches[@]}" -gt 0 ]; then
                            dropdown_lines=$(render_dropdown matches "$match_idx")
                        fi
                    elif [[ "$input" == /* ]]; then
                        # Update completion
                        local pattern="${input:1}"
                        mapfile -t matches < <(get_matches "$pattern")
                        match_idx=0

                        if [ "${#matches[@]}" -gt 0 ]; then
                            dropdown_lines=$(render_dropdown matches "$match_idx")
                        else
                            matches=()
                        fi
                    else
                        matches=()
                    fi
                fi
                ;;
        esac
    done
}
