#!/bin/bash

# cc_readline.sh - Custom readline input with inline slash completion

source "${CLAUDE_DIR:-$HOME/.claude}/bin/slash_complete.sh"

# ============================================================
# CUSTOM INPUT WITH INLINE COMPLETION
# ============================================================

# Read input with inline slash completion support
read_with_completion() {
    local input=""
    local suggestion=""
    local matches=()
    local match_idx=0

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
                    stty "$saved_stty"
                    echo ""
                    return 1
                fi
                ;;
            $'\x03')  # Ctrl+C
                stty "$saved_stty"
                echo "^C"
                return 2
                ;;
            $'\x7f')  # Backspace
                if [ -n "$input" ]; then
                    # Remove last character
                    input="${input:0:${#input}-1}"

                    # Clear line and redraw
                    printf '\r\033[K> %s' "$input"

                    # Update suggestions
                    if [[ "$input" == /* ]]; then
                        local pattern="${input:1}"
                        mapfile -t matches < <(get_matches "$pattern")
                        match_idx=0
                        [ "${#matches[@]}" -gt 0 ] && suggestion="${matches[$match_idx]}"
                    else
                        suggestion=""
                    fi

                    # Show suggestion
                    if [ -n "$suggestion" ]; then
                        local remaining="${suggestion:${#pattern}}"
                        printf '\033[90m%s\033[0m' "$remaining"
                        # Move cursor back
                        printf '\033[%sD' "${#remaining}"
                    fi
                fi
                ;;
            $'\n')  # Enter
                # Accept suggestion if any
                if [ -n "$suggestion" ] && [[ "$input" == /* ]]; then
                    input="/$suggestion"
                fi
                stty "$saved_stty"
                echo ""
                echo "$input"
                return 0
                ;;
            $'\t')  # Tab - accept current suggestion
                if [ -n "$suggestion" ] && [[ "$input" == /* ]]; then
                    input="/$suggestion"
                    # Clear and redraw
                    printf '\r\033[K> %s' "$input"
                    suggestion=""
                fi
                ;;
            $'\x1b')  # Escape sequence (arrow keys)
                # Read next two characters
                local seq
                IFS= read -r -n2 -t 0.01 seq

                if [[ "$input" == /* ]] && [ "${#matches[@]}" -gt 0 ]; then
                    local pattern="${input:1}"

                    case "$seq" in
                        '[C')  # Right arrow - next match
                            match_idx=$(((match_idx + 1) % ${#matches[@]}))
                            suggestion="${matches[$match_idx]}"
                            ;;
                        '[D')  # Left arrow - previous match
                            match_idx=$(((match_idx - 1 + ${#matches[@]}) % ${#matches[@]}))
                            suggestion="${matches[$match_idx]}"
                            ;;
                    esac

                    # Redraw with new suggestion
                    printf '\r\033[K> /%s' "$pattern"
                    if [ -n "$suggestion" ]; then
                        local remaining="${suggestion:${#pattern}}"
                        printf '\033[90m%s\033[0m' "$remaining"
                        printf '\033[%sD' "${#remaining}"
                    fi
                fi
                ;;
            *)
                # Regular character
                if [[ "$char" =~ [[:print:]] ]]; then
                    input="$input$char"

                    # Check if we're in slash completion mode
                    if [ "$char" = "/" ] && { [ -z "${input%/}" ] || [[ "${input%/}" == *[[:space:]] ]]; }; then
                        # Just typed /, start completion
                        mapfile -t matches < <(get_matches "")
                        match_idx=0
                        [ "${#matches[@]}" -gt 0 ] && suggestion="${matches[$match_idx]}"
                    elif [[ "$input" == /* ]]; then
                        # Update completion
                        local pattern="${input:1}"
                        mapfile -t matches < <(get_matches "$pattern")
                        match_idx=0
                        [ "${#matches[@]}" -gt 0 ] && suggestion="${matches[$match_idx]}"
                    else
                        suggestion=""
                    fi

                    # Redraw
                    printf '\r\033[K> %s' "$input"

                    # Show suggestion
                    if [ -n "$suggestion" ] && [[ "$input" == /* ]]; then
                        local pattern="${input:1}"
                        local remaining="${suggestion:${#pattern}}"
                        printf '\033[90m%s\033[0m' "$remaining"
                        printf '\033[%sD' "${#remaining}"
                    fi
                fi
                ;;
        esac
    done
}
