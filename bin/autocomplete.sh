#!/bin/bash
# autocomplete.sh - Autocomplete functionality for cc command

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
        $'\x04')  KEY_TYPE="CTRL_D" ;;
        *)        KEY_TYPE="CHAR"; KEY_CHAR="$char" ;;
    esac
}

# Render completion menu below current line
# Handles wrapped lines correctly by clearing to end of screen
render_autocomplete_menu() {
    local -n items=$1      # Array of items to show
    local selected=$2      # Currently selected index
    local max_show=10      # Max items to display

    local count=${#items[@]}
    [[ $count -eq 0 ]] && return

    # Get terminal width to prevent menu overflow
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)

    # Calculate how many items fit in terminal width
    # Leave 10 char margin for safety
    local available_width=$((term_width - 10))
    local menu_width=0
    local show=0

    for ((i=0; i<count && i<max_show; i++)); do
        # Each item: "/" + name + "  " (2 trailing spaces)
        local item_width=$((${#items[$i]} + 3))

        if ((menu_width + item_width > available_width)); then
            # Would overflow, stop adding items
            break
        fi

        menu_width=$((menu_width + item_width))
        show=$((show + 1))
    done

    # Always show at least 1 item even if it overflows
    [[ $show -eq 0 ]] && show=1

    printf '\033[s'        # Save cursor position (at end of input)

    # Clear from cursor to end of screen - handles wrapped lines and old menu remnants
    # This is essential for correct rendering when:
    # 1. Input line wraps to next physical row
    # 2. Previous menu was on a different row before wrap
    printf '\033[J'

    # Always use cursor movement to go to next line.
    # Never use printf '\n' as it can cause terminal scroll at bottom,
    # which invalidates the saved cursor position.
    printf '\033[E'        # Move to beginning of next line (down + column 0)

    # Render horizontal menu with space-separated items
    for ((i=0; i<show; i++)); do
        if [[ $i -eq $selected ]]; then
            printf '\033[7m/%s\033[0m  ' "${items[$i]}"
        else
            printf '/%s  ' "${items[$i]}"
        fi
    done

    printf '\033[u'        # Restore cursor to input position
}

# Clear the menu area and any wrapped line remnants
clear_autocomplete_menu() {
    printf '\033[s'        # Save cursor
    printf '\033[J'        # Clear from cursor to end of screen (handles wrapped lines)
    printf '\033[u'        # Restore cursor
}

# Run autocomplete mode, return selected command or empty
# Sets AUTOCOMPLETE_RESULT
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
                clear_autocomplete_menu
                render_autocomplete_menu filtered_commands $selected
                ;;

            BACKSPACE)
                if [[ ${#input} -gt 1 ]]; then
                    # Only erase if we have characters after the /
                    input="${input%?}"
                    printf '\b \b'  # Erase one char
                    # Re-filter
                    local prefix="${input#/}"
                    mapfile -t filtered_commands < <(
                        printf '%s\n' "${all_commands[@]}" | filter_commands "$prefix"
                    )
                    selected=0
                    clear_autocomplete_menu
                    render_autocomplete_menu filtered_commands $selected
                elif [[ ${#input} -eq 1 ]]; then
                    # Backspacing the / itself - exit autocomplete cleanly
                    # Clear menu first, then erase ONLY the /, leaving "> " intact
                    clear_autocomplete_menu
                    printf '\033[D\033[K'  # Move left one position and clear to end of line (works with wrapped lines)
                    AUTOCOMPLETE_RESULT=""
                    return 1
                fi
                # If input is empty (shouldn't happen), do nothing to prevent erasing prompt
                ;;

            UP)
                if [[ $selected -gt 0 ]]; then
                    ((selected--))
                    clear_autocomplete_menu
                    render_autocomplete_menu filtered_commands $selected
                fi
                ;;

            DOWN)
                if [[ $selected -lt $((${#filtered_commands[@]} - 1)) ]] && [[ $selected -lt 9 ]]; then
                    ((selected++))
                    clear_autocomplete_menu
                    render_autocomplete_menu filtered_commands $selected
                fi
                ;;

            ENTER)
                clear_autocomplete_menu
                if [[ ${#filtered_commands[@]} -gt 0 ]]; then
                    # Clear current line and print full command
                    printf '\r\033[K> /%s\n' "${filtered_commands[$selected]}"
                    AUTOCOMPLETE_RESULT="/${filtered_commands[$selected]}"
                else
                    printf '\n'
                    AUTOCOMPLETE_RESULT="$input"
                fi
                return 0
                ;;

            ESCAPE|CTRL_C)
                clear_autocomplete_menu
                printf '\r\033[K'  # Clear line
                AUTOCOMPLETE_RESULT=""
                return 1
                ;;

            CTRL_D)
                clear_autocomplete_menu
                printf '\n'
                AUTOCOMPLETE_RESULT=""
                return 2  # Special code for exit
                ;;
        esac
    done
}
