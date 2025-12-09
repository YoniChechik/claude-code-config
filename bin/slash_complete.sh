#!/bin/bash

# slash_complete.sh - Fuzzy search for slash commands

COMMANDS_DIR="${COMMANDS_DIR:-$HOME/.claude/commands}"

# ============================================================
# COMMAND DISCOVERY
# ============================================================
get_commands() {
    local cmds=()
    if [ -d "$COMMANDS_DIR" ]; then
        while IFS= read -r file; do
            local cmd=$(basename "$file" .md)
            cmds+=("$cmd")
        done < <(ls "$COMMANDS_DIR"/*.md 2>/dev/null)
    fi
    printf '%s\n' "${cmds[@]}"
}

# ============================================================
# FUZZY MATCHING
# ============================================================
fuzzy_match() {
    local pattern="$1"
    local candidate="$2"

    # Empty pattern matches everything
    [ -z "$pattern" ] && return 0

    # Simple substring match (case insensitive)
    if [[ "${candidate,,}" == *"${pattern,,}"* ]]; then
        return 0
    fi

    return 1
}

# Score a match (lower is better)
fuzzy_score() {
    local pattern="$1"
    local candidate="$2"

    # Exact match
    if [ "$pattern" = "$candidate" ]; then
        echo "0"
        return
    fi

    # Prefix match
    if [[ "$candidate" == "$pattern"* ]]; then
        echo "1"
        return
    fi

    # Position of first character
    local pos="${candidate%%$pattern*}"
    echo "$((100 + ${#pos}))"
}

# Get matching commands sorted by score
get_matches() {
    local pattern="$1"
    local -a matches=()
    local -a scores=()

    while IFS= read -r cmd; do
        if fuzzy_match "$pattern" "$cmd"; then
            matches+=("$cmd")
            scores+=("$(fuzzy_score "$pattern" "$cmd")")
        fi
    done < <(get_commands)

    # Sort by score
    local n=${#matches[@]}
    for ((i=0; i<n; i++)); do
        echo "${scores[$i]} ${matches[$i]}"
    done | sort -n | cut -d' ' -f2-
}

# ============================================================
# TERMINAL CONTROL
# ============================================================

# Save terminal state
save_terminal() {
    SAVED_STTY=$(stty -g)
    stty raw -echo 2>/dev/null
}

# Restore terminal state
restore_terminal() {
    stty "$SAVED_STTY" 2>/dev/null
}

# Read a single character (handles escape sequences)
read_char() {
    local char
    IFS= read -r -n1 char
    echo -n "$char"
}

# Read escape sequence (arrow keys, etc.)
read_escape_seq() {
    local seq=""
    local char

    # Read [
    IFS= read -r -n1 -t 0.01 char || return
    seq="$char"

    if [ "$char" = "[" ]; then
        # Read next char (A, B, C, D for arrows)
        IFS= read -r -n1 -t 0.01 char || return
        seq="$seq$char"
    fi

    echo -n "$seq"
}

# ============================================================
# RENDERING
# ============================================================

# Move cursor back N positions
cursor_back() {
    [ "$1" -gt 0 ] && printf '\033[%sD' "$1"
}

# Clear from cursor to end of line
clear_to_eol() {
    printf '\033[K'
}

# Render suggestion in gray
render_suggestion() {
    local current="$1"
    local suggestion="$2"

    if [ -n "$suggestion" ]; then
        # Show the part of suggestion after current text
        local remaining="${suggestion:${#current}}"
        printf '\033[90m%s\033[0m' "$remaining"
    fi
}

# ============================================================
# MAIN COMPLETION FUNCTION
# ============================================================

# Run interactive slash completion
# Returns: completed command or empty string if cancelled
slash_complete() {
    local prefix="$1"  # Text before the slash
    local input=""     # What user typed after /
    local suggestions=()
    local current_idx=0

    # Setup
    save_terminal
    trap 'restore_terminal' EXIT INT TERM

    # Initial display
    printf "/"

    while true; do
        # Get current suggestions
        mapfile -t suggestions < <(get_matches "$input")

        # Clamp index
        local n=${#suggestions[@]}
        [ $n -eq 0 ] && current_idx=0 || current_idx=$((current_idx % n))

        local current_suggestion="${suggestions[$current_idx]:-}"

        # Render current state (overwrite line)
        local backtrack=$((${#input} + 50))  # Rough estimate
        cursor_back "$backtrack"
        clear_to_eol
        printf "/%s" "$input"
        render_suggestion "$input" "$current_suggestion"

        # Read input
        local char=$(read_char)

        case "$char" in
            $'\x7f')  # Backspace
                if [ -n "$input" ]; then
                    input="${input:0:${#input}-1}"
                    current_idx=0
                else
                    # Backspace on empty = cancel
                    restore_terminal
                    cursor_back $((${#input} + 1))
                    clear_to_eol
                    return 1
                fi
                ;;
            $'\x1b')  # Escape or arrow key
                local seq=$(read_escape_seq)
                case "$seq" in
                    "[C")  # Right arrow - next suggestion
                        [ $n -gt 0 ] && current_idx=$(((current_idx + 1) % n))
                        ;;
                    "[D")  # Left arrow - prev suggestion
                        [ $n -gt 0 ] && current_idx=$(((current_idx - 1 + n) % n))
                        ;;
                    "")    # Escape alone - cancel
                        restore_terminal
                        cursor_back $((${#input} + 1))
                        clear_to_eol
                        return 1
                        ;;
                esac
                ;;
            $'\t'|$'\n')  # Tab or Enter - accept
                restore_terminal
                cursor_back $((${#input} + 1))
                clear_to_eol
                if [ -n "$current_suggestion" ]; then
                    echo "/$current_suggestion"
                    return 0
                else
                    echo "/$input"
                    return 0
                fi
                ;;
            $'\x03')  # Ctrl+C - cancel
                restore_terminal
                cursor_back $((${#input} + 1))
                clear_to_eol
                return 1
                ;;
            *)
                # Regular character - add to input
                if [[ "$char" =~ [[:print:]] ]]; then
                    input="$input$char"
                    current_idx=0
                fi
                ;;
        esac
    done
}

# ============================================================
# LIBRARY MODE
# ============================================================

# If sourced, just export functions. If executed, run tests or commands.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Direct execution - run command based on args
    case "${1:-}" in
        get_commands)
            get_commands
            ;;
        get_matches)
            get_matches "${2:-}"
            ;;
        test)
            slash_complete ""
            ;;
        *)
            echo "Usage: $0 {get_commands|get_matches <pattern>|test}"
            exit 1
            ;;
    esac
fi
