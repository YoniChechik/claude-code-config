#!/bin/bash

find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]] || [[ -d "$dir/.claude" ]]; then
            echo "$dir"
            return
        fi
        dir="$(dirname "$dir")"
    done
}

get_slash_commands() {
    declare -A seen
    local cmds=()

    # 1. User commands (highest priority) - always from ~/.claude
    if [[ -d "$HOME/.claude/commands" ]]; then
        for f in "$HOME/.claude/commands"/*.md; do
            [[ -f "$f" ]] || continue
            local name="$(basename "$f" .md)"
            cmds+=("$name")
            seen[$name]=1
        done
    fi

    # 2. Project commands (from .claude/commands in project root)
    local project_root
    project_root=$(find_project_root)
    if [[ -n "$project_root" && -d "$project_root/.claude/commands" ]]; then
        for f in "$project_root/.claude/commands"/*.md; do
            [[ -f "$f" ]] || continue
            local name="$(basename "$f" .md)"
            [[ ${seen[$name]+_} ]] && continue
            cmds+=("$name")
            seen[$name]=1
        done
    fi

    # 3. Claude built-in commands (lowest priority)
    local builtins=(bug clear compact config cost doctor help init login logout mcp memory model permissions review status terminal-setup vim)
    for name in "${builtins[@]}"; do
        [[ ${seen[$name]+_} ]] && continue
        cmds+=("$name")
    done

    printf '%s\n' "${cmds[@]}" | sort
}

fuzzy_score() {
    local pattern="${1,,}"
    local candidate="${2,,}"

    [[ "$pattern" == "$candidate" ]] && { echo 0; return; }
    [[ "$candidate" == "$pattern"* ]] && { echo 1; return; }

    echo 999
}

fuzzy_match() {
    local pattern="$1"
    local cmd score

    while IFS= read -r cmd; do
        score=$(fuzzy_score "$pattern" "$cmd")
        [[ $score -lt 999 ]] && echo "$score $cmd"
    done < <(get_slash_commands) | sort -n | cut -d' ' -f2-
}

SAVED_TTY=""

save_terminal_state() {
    SAVED_TTY=$(stty -g 2>/dev/null)
    stty -echo -icanon min 1 2>/dev/null
}

restore_terminal_state() {
    [[ -n "$SAVED_TTY" ]] && stty "$SAVED_TTY" 2>/dev/null
    SAVED_TTY=""
}

read_key() {
    local char
    IFS= read -rsn1 char

    case "$char" in
        $'\t')           KEY_TYPE="TAB" ;;
        $'\n')           KEY_TYPE="ENTER" ;;
        $'\x7f'|$'\x08') KEY_TYPE="BACKSPACE" ;;
        $'\x03')         KEY_TYPE="CTRL_C" ;;
        $'\x04')         KEY_TYPE="CTRL_D" ;;
        $'\x1b')
            # Read escape sequence for arrow keys
            IFS= read -rsn1 -t 0.1 char2
            IFS= read -rsn1 -t 0.1 char3
            case "$char2$char3" in
                '[A') KEY_TYPE="ARROW_UP" ;;
                '[B') KEY_TYPE="ARROW_DOWN" ;;
                *)    KEY_TYPE="ESCAPE" ;;
            esac
            ;;
        '')              KEY_TYPE="ENTER" ;;
        *)               KEY_TYPE="CHAR"; KEY_VALUE="$char" ;;
    esac
}

C_GRAY='\033[90m'
C_RESET='\033[0m'
PREV_RENDER_LINES=1

render_inline() {
    local input="$1"
    local suggestion="$2"

    # Move up to first line of our output (if we wrapped before)
    if [[ $PREV_RENDER_LINES -gt 1 ]]; then
        printf '\033[%dA' $((PREV_RENDER_LINES - 1)) > /dev/tty
    fi

    # Move to column 0 and clear to end of screen
    printf '\r\033[J' > /dev/tty

    # Print prompt and input
    printf '> %s' "$input" > /dev/tty

    # Print suggestion if any
    if [[ -n "$suggestion" ]]; then
        local remaining="${suggestion:${#input}}"
        printf "${C_GRAY}%s${C_RESET}" "$remaining" > /dev/tty
    fi

    # Calculate how many lines we just used
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)
    local display_len=$((2 + ${#input}))  # "> " + input
    if [[ -n "$suggestion" ]]; then
        display_len=$((display_len + ${#suggestion} - ${#input}))
    fi
    PREV_RENDER_LINES=$(( (display_len + term_width - 1) / term_width ))
    [[ $PREV_RENDER_LINES -lt 1 ]] && PREV_RENDER_LINES=1

    # Move cursor back to end of input (before suggestion)
    local backtrack=$((${#suggestion} - ${#input}))
    [[ $backtrack -gt 0 ]] && printf '\033[%dD' "$backtrack" > /dev/tty
}

clear_line() {
    # Clear all lines from previous render
    if [[ $PREV_RENDER_LINES -gt 1 ]]; then
        printf '\033[%dA' $((PREV_RENDER_LINES - 1)) > /dev/tty
    fi
    printf '\r\033[J> ' > /dev/tty
    PREV_RENDER_LINES=1
}

read_with_autosuggest() {
    local input=""
    local matches=()
    local match_idx=0
    local suggest_mode=false

    save_terminal_state
    trap 'restore_terminal_state' EXIT INT TERM

    clear_line

    while true; do
        read_key

        case "$KEY_TYPE" in
            CHAR)
                input="${input}${KEY_VALUE}"

                if [[ "$KEY_VALUE" == "/" ]] && [[ "$input" =~ ^/$ || "$input" =~ [[:space:]]/$ ]]; then
                    suggest_mode=true
                    mapfile -t matches < <(fuzzy_match "")
                    match_idx=0
                fi

                if [[ "$suggest_mode" == true ]]; then
                    local pattern="${input##*/}"
                    mapfile -t matches < <(fuzzy_match "$pattern")
                    match_idx=0
                fi

                local suggestion=""
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    suggestion="${base}${matches[$match_idx]}"
                fi
                render_inline "$input" "$suggestion"
                ;;

            TAB)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    # Accept suggestion, append space, continue editing
                    local base="${input%/*}/"
                    input="${base}${matches[$match_idx]} "
                    suggest_mode=false
                    matches=()
                    render_inline "$input" ""
                fi
                ;;

            ARROW_DOWN)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    match_idx=$(( (match_idx + 1) % ${#matches[@]} ))
                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion"
                fi
                ;;

            ARROW_UP)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    match_idx=$(( (match_idx - 1 + ${#matches[@]}) % ${#matches[@]} ))
                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion"
                fi
                ;;

            ENTER)
                # Send the input (with or without suggestion)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    input="${base}${matches[$match_idx]}"
                fi
                restore_terminal_state
                echo "" > /dev/tty
                echo "$input"
                return 0
                ;;

            BACKSPACE)
                if [[ -n "$input" ]]; then
                    input="${input:0:${#input}-1}"

                    if [[ ! "$input" =~ / ]]; then
                        suggest_mode=false
                        matches=()
                    elif [[ "$suggest_mode" == true ]]; then
                        local pattern="${input##*/}"
                        mapfile -t matches < <(fuzzy_match "$pattern")
                        match_idx=0
                    fi

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
                echo "^C" > /dev/tty
                return 2
                ;;

            CTRL_D)
                if [[ -z "$input" ]]; then
                    restore_terminal_state
                    echo "" > /dev/tty
                    return 1
                fi
                ;;
        esac
    done
}
