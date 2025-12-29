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
PASTE_MODE=false

save_terminal_state() {
    SAVED_TTY=$(stty -g 2>/dev/null)
    stty -echo -icanon min 1 2>/dev/null
    printf '\033[?2004h' > /dev/tty
}

restore_terminal_state() {
    printf '\033[?2004l' > /dev/tty
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
        $'\x17')         KEY_TYPE="CTRL_BACKSPACE" ;;
        $'\x03')         KEY_TYPE="CTRL_C" ;;
        $'\x04')         KEY_TYPE="CTRL_D" ;;
        $'\x1b')
            # Read escape sequence for arrow keys, Ctrl+Arrow keys, and bracketed paste
            IFS= read -rsn1 -t 0.5 char2
            IFS= read -rsn1 -t 0.5 char3
            case "$char2$char3" in
                '[A') KEY_TYPE="ARROW_UP" ;;
                '[B') KEY_TYPE="ARROW_DOWN" ;;
                '[C') KEY_TYPE="ARROW_RIGHT" ;;
                '[D') KEY_TYPE="ARROW_LEFT" ;;
                '[1')
                    # Possibly Ctrl+Arrow (needs more bytes: [1;5C or [1;5D)
                    IFS= read -rsn1 -t 0.5 char4
                    IFS= read -rsn1 -t 0.5 char5
                    IFS= read -rsn1 -t 0.5 char6
                    case "$char4$char5$char6" in
                        ';5C') KEY_TYPE="CTRL_ARROW_RIGHT" ;;
                        ';5D') KEY_TYPE="CTRL_ARROW_LEFT" ;;
                        *)     KEY_TYPE="ESCAPE" ;;
                    esac
                    ;;
                '[2')
                    # Possibly bracketed paste start: [200~ or end: [201~
                    IFS= read -rsn1 -t 0.5 char4
                    IFS= read -rsn1 -t 0.5 char5
                    IFS= read -rsn1 -t 0.5 char6
                    case "$char4$char5$char6" in
                        '00~') KEY_TYPE="PASTE_START"; PASTE_MODE=true ;;
                        '01~') KEY_TYPE="PASTE_END"; PASTE_MODE=false ;;
                        *)     KEY_TYPE="ESCAPE" ;;
                    esac
                    ;;
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
    local cursor_pos="$3"

    # Calculate how many lines our content will occupy
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)

    # Calculate cursor line position (0-indexed from start of our content)
    local cursor_col=$((2 + cursor_pos))  # "> " + cursor_pos
    local cursor_line=$((cursor_col / term_width))

    # Calculate total display length
    local display_len=$((2 + ${#input}))  # "> " + input
    if [[ -n "$suggestion" ]]; then
        display_len=$((display_len + ${#suggestion} - ${#input}))
    fi
    local total_lines=$(( (display_len + term_width - 1) / term_width ))
    [[ $total_lines -lt 1 ]] && total_lines=1

    # Move up to first line of our output (if we wrapped before)
    if [[ $PREV_RENDER_LINES -gt 1 ]]; then
        printf '\033[%dA' $((PREV_RENDER_LINES - 1)) > /dev/tty
    fi

    # Move to column 0
    printf '\r' > /dev/tty

    # Clear each line we previously occupied (using \033[K per line, not \033[J)
    for ((i = 0; i < PREV_RENDER_LINES; i++)); do
        printf '\033[K' > /dev/tty
        if [[ $i -lt $((PREV_RENDER_LINES - 1)) ]]; then
            printf '\033[B' > /dev/tty  # Move down
        fi
    done

    # Move back up to first line
    if [[ $PREV_RENDER_LINES -gt 1 ]]; then
        printf '\033[%dA' $((PREV_RENDER_LINES - 1)) > /dev/tty
    fi
    printf '\r' > /dev/tty

    # Print prompt and input up to cursor
    printf '> %s' "${input:0:$cursor_pos}" > /dev/tty

    # Save cursor position (this is where cursor should end up)
    printf '\033[s' > /dev/tty

    # Print rest of input after cursor
    printf '%s' "${input:$cursor_pos}" > /dev/tty

    # Print suggestion if any
    if [[ -n "$suggestion" ]]; then
        local remaining="${suggestion:${#input}}"
        printf "${C_GRAY}%s${C_RESET}" "$remaining" > /dev/tty
    fi

    # Update line count for next render
    PREV_RENDER_LINES=$total_lines

    # Restore cursor to saved position (where user is editing)
    printf '\033[u' > /dev/tty
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
    local cursor_pos=0
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
                # Insert character at cursor position
                input="${input:0:$cursor_pos}${KEY_VALUE}${input:$cursor_pos}"
                cursor_pos=$((cursor_pos + 1))

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
                render_inline "$input" "$suggestion" "$cursor_pos"
                ;;

            TAB)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    # Accept suggestion, append space, continue editing
                    local base="${input%/*}/"
                    input="${base}${matches[$match_idx]} "
                    cursor_pos=${#input}
                    suggest_mode=false
                    matches=()
                    render_inline "$input" "" "$cursor_pos"
                fi
                ;;

            ARROW_DOWN)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    match_idx=$(( (match_idx + 1) % ${#matches[@]} ))
                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            ARROW_UP)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    match_idx=$(( (match_idx - 1 + ${#matches[@]}) % ${#matches[@]} ))
                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            ARROW_RIGHT)
                if [[ $cursor_pos -lt ${#input} ]]; then
                    cursor_pos=$((cursor_pos + 1))
                    local suggestion=""
                    if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                        local base="${input%/*}/"
                        suggestion="${base}${matches[$match_idx]}"
                    fi
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            ARROW_LEFT)
                if [[ $cursor_pos -gt 0 ]]; then
                    cursor_pos=$((cursor_pos - 1))
                    local suggestion=""
                    if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                        local base="${input%/*}/"
                        suggestion="${base}${matches[$match_idx]}"
                    fi
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            CTRL_ARROW_RIGHT)
                # Jump to next word boundary (space or end)
                while [[ $cursor_pos -lt ${#input} ]]; do
                    cursor_pos=$((cursor_pos + 1))
                    [[ $cursor_pos -ge ${#input} ]] && break
                    [[ "${input:$cursor_pos:1}" == " " ]] && { cursor_pos=$((cursor_pos + 1)); break; }
                done
                local suggestion=""
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    suggestion="${base}${matches[$match_idx]}"
                fi
                render_inline "$input" "$suggestion" "$cursor_pos"
                ;;

            CTRL_ARROW_LEFT)
                # Jump to previous word boundary (space or start)
                [[ $cursor_pos -gt 0 ]] && cursor_pos=$((cursor_pos - 1))
                while [[ $cursor_pos -gt 0 ]]; do
                    [[ "${input:$((cursor_pos-1)):1}" == " " ]] && break
                    cursor_pos=$((cursor_pos - 1))
                done
                local suggestion=""
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    suggestion="${base}${matches[$match_idx]}"
                fi
                render_inline "$input" "$suggestion" "$cursor_pos"
                ;;

            ENTER)
                if [[ "$PASTE_MODE" == true ]]; then
                    # Inside bracketed paste: insert literal newline
                    input="${input:0:$cursor_pos}"$'\n'"${input:$cursor_pos}"
                    cursor_pos=$((cursor_pos + 1))
                    local suggestion=""
                    if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                        local base="${input%/*}/"
                        suggestion="${base}${matches[$match_idx]}"
                    fi
                    render_inline "$input" "$suggestion" "$cursor_pos"
                else
                    # Send the input (with or without suggestion)
                    if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                        local base="${input%/*}/"
                        input="${base}${matches[$match_idx]}"
                    fi
                    restore_terminal_state
                    echo "" > /dev/tty
                    echo "$input"
                    return 0
                fi
                ;;

            BACKSPACE)
                if [[ $cursor_pos -gt 0 ]]; then
                    # Delete character before cursor
                    input="${input:0:$((cursor_pos-1))}${input:$cursor_pos}"
                    cursor_pos=$((cursor_pos - 1))

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
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            CTRL_BACKSPACE)
                if [[ $cursor_pos -gt 0 ]]; then
                    local new_pos=$cursor_pos
                    # Skip whitespace backward
                    while [[ $new_pos -gt 0 ]] && [[ "${input:$((new_pos-1)):1}" =~ [[:space:]] ]]; do
                        ((new_pos--))
                    done
                    # Skip word characters backward
                    while [[ $new_pos -gt 0 ]] && [[ ! "${input:$((new_pos-1)):1}" =~ [[:space:]] ]]; do
                        ((new_pos--))
                    done
                    # Delete from new_pos to cursor_pos
                    input="${input:0:$new_pos}${input:$cursor_pos}"
                    cursor_pos=$new_pos

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
                    render_inline "$input" "$suggestion" "$cursor_pos"
                fi
                ;;

            CTRL_C)
                # Clear display and show cursor before restoring terminal
                printf '\r\033[J' > /dev/tty
                printf '\033[?25h' > /dev/tty
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

            PASTE_START)
                local pasted_content=""
                while true; do
                    # Read raw character without escape sequence interpretation
                    local char
                    IFS= read -rsn1 -t 0.5 char

                    # Skip empty strings from timeout
                    [[ -z "$char" ]] && continue

                    # Check for PASTE_END sequence: \x1b[201~
                    if [[ "$char" == $'\x1b' ]]; then
                        local seq="$char"
                        IFS= read -rsn1 -t 0.5 c2
                        seq+="$c2"

                        if [[ "$c2" == '[' ]]; then
                            IFS= read -rsn1 -t 0.5 c3
                            IFS= read -rsn1 -t 0.5 c4
                            IFS= read -rsn1 -t 0.5 c5
                            IFS= read -rsn1 -t 0.5 c6
                            seq+="$c3$c4$c5$c6"

                            if [[ "$c3$c4$c5$c6" == "201~" ]]; then
                                PASTE_MODE=false
                                break
                            else
                                pasted_content+="$seq"
                            fi
                        else
                            pasted_content+="$seq"
                        fi
                    else
                        pasted_content+="$char"
                    fi
                done

                input="${input:0:$cursor_pos}${pasted_content}${input:$cursor_pos}"
                cursor_pos=$((cursor_pos + ${#pasted_content}))

                # Re-render with any current suggestion
                local suggestion=""
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    local base="${input%/*}/"
                    suggestion="${base}${matches[$match_idx]}"
                fi
                render_inline "$input" "$suggestion" "$cursor_pos"
                ;;

            PASTE_END)
                # Should not reach here (handled inside PASTE_START loop)
                ;;
        esac
    done
}
