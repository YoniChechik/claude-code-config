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
        $'\x1b')         KEY_TYPE="ESCAPE" ;;
        '')              KEY_TYPE="ENTER" ;;
        *)               KEY_TYPE="CHAR"; KEY_VALUE="$char" ;;
    esac
}

C_GRAY='\033[90m'
C_RESET='\033[0m'

render_inline() {
    local input="$1"
    local suggestion="$2"

    printf '\r\033[K' > /dev/tty
    printf '> %s' "$input" > /dev/tty

    if [[ -n "$suggestion" ]]; then
        local remaining="${suggestion:${#input}}"
        printf "${C_GRAY}%s${C_RESET}" "$remaining" > /dev/tty
    fi

    local backtrack=${#suggestion}
    backtrack=$((backtrack - ${#input}))
    [[ $backtrack -gt 0 ]] && printf '\033[%dD' "$backtrack" > /dev/tty
}

clear_line() {
    printf '\r\033[K> ' > /dev/tty
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
                    match_idx=$(( (match_idx + 1) % ${#matches[@]} ))

                    local base="${input%/*}/"
                    local suggestion="${base}${matches[$match_idx]}"
                    render_inline "$input" "$suggestion"
                fi
                ;;

            ENTER)
                if [[ "$suggest_mode" == true ]] && [[ ${#matches[@]} -gt 0 ]]; then
                    # Accept suggestion, append space, continue editing
                    local base="${input%/*}/"
                    input="${base}${matches[$match_idx]} "
                    suggest_mode=false
                    matches=()
                    render_inline "$input" ""
                else
                    # No suggestion - send the input
                    restore_terminal_state
                    echo "" > /dev/tty
                    echo "$input"
                    return 0
                fi
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
