#!/usr/bin/env bash

_guard_expand_home() {
    local token="$1"
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local tilde='~'
    case "$token" in
        "$tilde") token="$HOME" ;;
        "$tilde"/*) token="$HOME/${token#"$tilde"/}" ;;
        '$HOME') token="$HOME" ;;
        '$HOME/'*) token="$HOME/${token#\$HOME/}" ;;
        '${HOME}') token="$HOME" ;;
        '${HOME}/'*) token="$HOME/${token#\$\{HOME\}/}" ;;
        '$CLAUDE_CONFIG_DIR') token="$claude_dir" ;;
        '$CLAUDE_CONFIG_DIR/'*) token="$claude_dir/${token#\$CLAUDE_CONFIG_DIR/}" ;;
    esac
    GUARD_REPLY="$token"
}

_resolve_path() {
    local base="$1"
    _guard_expand_home "$2"
    python3 -c '
import os, sys
base, p = sys.argv[1], sys.argv[2]
if not os.path.isabs(p):
    p = os.path.join(base, p)
print(os.path.realpath(p))
' "$base" "$GUARD_REPLY" 2>/dev/null
}

_ws_collapse() {
    local s="$1"
    s="${s//$'\t'/ }"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    while [ "${s#*  }" != "$s" ]; do
        s="${s//  / }"
    done
    s="${s# }"
    s="${s% }"
    GUARD_REPLY="$s"
}

_sanitize_shell_text() {
    local s=$1
    local n=${#s}
    local i=0
    local out=""
    local stack="N"
    local depth="0"
    local heredocs=""
    local c c2 top j q delim ch rest chunk line stripped d entry lead
    local code_arg_lead='(^|[;&|(`]|[[:space:]])(eval|(bash|sh|zsh|dash|ksh)[[:space:]]+-[A-Za-z]*c[A-Za-z]*)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$'

    while [ "$i" -lt "$n" ]; do
        top=${stack##* }
        c=${s:i:1}

        if [ "$top" = "S" ]; then
            if [ "$c" = "'" ]; then
                stack=${stack% *}
                out+=" "
                i=$((i + 1))
                continue
            fi
            rest=${s:i}
            chunk=${rest%%\'*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        if [ "$top" = "D" ]; then
            if [ "$c" = '\' ]; then out+=" "; i=$((i + 2)); continue; fi
            if [ "$c" = '"' ]; then stack=${stack% *}; out+=" "; i=$((i + 1)); continue; fi
            if [ "$c" = '`' ]; then stack="$stack B"; out+="("; i=$((i + 1)); continue; fi
            if [ "$c" = '$' ]; then
                if [ "${s:i+1:1}" = "(" ]; then
                    stack="$stack P"; depth="$depth 1"; out+='$('; i=$((i + 2)); continue
                fi
                i=$((i + 1)); continue
            fi
            rest=${s:i}
            chunk=${rest%%[\`\"\$\\]*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        if [ "$c" = '\' ]; then
            c2=${s:i+1:1}
            case "$c2" in
                [A-Za-z0-9]) out+="$c2" ;;
                *) out+=" " ;;
            esac
            i=$((i + 2)); continue
        fi
        if [ "$c" = "'" ]; then
            lead="${out##*$'\n'}"
            if [ "$top" = "SC" ]; then stack=${stack% *}
            elif [[ "$lead" =~ $code_arg_lead ]]; then stack="$stack SC"
            else stack="$stack S"; fi
            out+=" "; i=$((i + 1)); continue
        fi
        if [ "$c" = '"' ]; then
            lead="${out##*$'\n'}"
            if [ "$top" = "DC" ]; then stack=${stack% *}
            elif [[ "$lead" =~ $code_arg_lead ]]; then stack="$stack DC"
            else stack="$stack D"; fi
            out+=" "; i=$((i + 1)); continue
        fi
        if [ "$c" = '`' ]; then
            if [ "$top" = "B" ]; then stack=${stack% *}; out+=")"; else stack="$stack B"; out+="("; fi
            i=$((i + 1)); continue
        fi
        if [ "$c" = '$' ] && [ "${s:i+1:1}" = "(" ]; then
            stack="$stack P"; depth="$depth 1"; out+='$('; i=$((i + 2)); continue
        fi
        if [ "$c" = "(" ]; then
            if [ "$top" = "P" ]; then d=${depth##* }; depth="${depth% *} $((d + 1))"; fi
            out+="("; i=$((i + 1)); continue
        fi
        if [ "$c" = ")" ]; then
            out+=")"
            if [ "$top" = "P" ]; then
                d=${depth##* }; d=$((d - 1))
                if [ "$d" -le 0 ]; then stack=${stack% *}; depth=${depth% *}
                else depth="${depth% *} $d"; fi
            fi
            i=$((i + 1)); continue
        fi
        if [ "$c" = "<" ] && [ "${s:i+1:1}" = "<" ] && [ "${s:i+2:1}" != "<" ]; then
            j=$((i + 2))
            [ "${s:j:1}" = "-" ] && j=$((j + 1))
            while [ "${s:j:1}" = " " ] || [ "${s:j:1}" = "	" ]; do j=$((j + 1)); done
            q=""
            if [ "${s:j:1}" = "'" ] || [ "${s:j:1}" = '"' ]; then q=${s:j:1}; j=$((j + 1)); fi
            delim=""
            while [ "$j" -lt "$n" ]; do
                ch=${s:j:1}
                if [ -n "$q" ]; then
                    if [ "$ch" = "$q" ]; then j=$((j + 1)); break; fi
                else
                    case "$ch" in [A-Za-z0-9_.-]) ;; *) break ;; esac
                fi
                delim="$delim$ch"; j=$((j + 1))
            done
            if [ -n "$delim" ]; then
                if [ -n "$q" ]; then heredocs="$heredocs Q:$delim"; else heredocs="$heredocs U:$delim"; fi
            fi
            out+=" "; i=$j; continue
        fi
        if [ "$c" = $'\n' ]; then
            out+=$'\n'; i=$((i + 1))
            while [ -n "$heredocs" ]; do
                heredocs=${heredocs# }
                entry=${heredocs%% *}
                if [ "$entry" = "$heredocs" ]; then heredocs=""; else heredocs=${heredocs#* }; fi
                q=${entry%%:*}
                delim=${entry#*:}
                while [ "$i" -lt "$n" ]; do
                    rest=${s:i}
                    line=${rest%%$'\n'*}
                    if [ "$line" = "$rest" ]; then i=$n; else i=$((i + ${#line} + 1)); fi
                    stripped=${line#"${line%%[![:space:]]*}"}
                    stripped=${stripped%"${stripped##*[![:space:]]}"}
                    [ "$stripped" = "$delim" ] && break
                    if [ "$q" = "U" ]; then
                        _guard_collect_substitutions "$line"
                        [ -n "$GUARD_REPLY" ] && out+=" $GUARD_REPLY "
                    fi
                done
            done
            continue
        fi
        rest=${s:i}
        chunk=${rest%%[\\\'\"\`\$()\<$'\n']*}
        if [ "$chunk" = "$rest" ]; then
            out+="$rest"; i=$n
        elif [ -z "$chunk" ]; then
            out+="$c"; i=$((i + 1))
        else
            out+="$chunk"; i=$((i + ${#chunk}))
        fi
    done

    GUARD_REPLY="$out"
}

_guard_collect_substitutions() {
    local s="$1"
    local n=${#s} i=0 c out="" j d
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        if [ "$c" = '$' ] && [ "${s:i+1:1}" = "(" ]; then
            d=0; j=$((i + 1))
            while [ "$j" -lt "$n" ]; do
                case "${s:j:1}" in
                    "(") d=$((d + 1)) ;;
                    ")") d=$((d - 1)); [ "$d" -le 0 ] && break ;;
                esac
                j=$((j + 1))
            done
            out+=" (${s:i+2:j-i-2}) "
            i=$((j + 1)); continue
        fi
        if [ "$c" = '`' ]; then
            j=$((i + 1))
            while [ "$j" -lt "$n" ] && [ "${s:j:1}" != '`' ]; do j=$((j + 1)); done
            out+=" (${s:i+1:j-i-1}) "
            i=$((j + 1)); continue
        fi
        i=$((i + 1))
    done
    GUARD_REPLY="$out"
}

_extract_subshell_spans() {
    local s="$1"
    local n=${#s}
    local i=0
    local c top rest chunk
    local starts=""
    while [ "$i" -lt "$n" ]; do
        rest=${s:i}
        chunk=${rest%%[()]*}
        [ "$chunk" = "$rest" ] && break
        i=$((i + ${#chunk}))
        c=${s:i:1}
        if [ "$c" = "(" ]; then
            starts="$starts $i"
        elif [ -n "$starts" ]; then
            top=${starts##* }
            starts=${starts% *}
            printf '%s\n' "${s:top+1:i-top-1}"
        fi
        i=$((i + 1))
    done
    while [ -n "$starts" ]; do
        top=${starts##* }
        starts=${starts% *}
        printf '%s\n' "${s:top+1}"
    done
}

_strip_leading_wrappers() {
    local seg="$1"
    local prev=""
    local head rest_prev tok
    while [ "$seg" != "$prev" ]; do
        prev="$seg"
        seg="${seg#"${seg%%[![:space:]]*}"}"

        case "$seg" in
            '{'|'}'|'('|')'|'!') seg=""; continue ;;
            '{'[[:space:]]*|'}'[[:space:]]*|'('[[:space:]]*|')'[[:space:]]*|'!'[[:space:]]*)
                seg="${seg:1}"; continue ;;
        esac

        head="${seg%%[[:space:]]*}"

        case "$head" in
            if|then|elif|else|fi|while|until|do|done|for|case|'esac'|in|time|coproc)
                if [ "$head" = "$seg" ]; then seg=""; else seg="${seg#*[[:space:]]}"; fi
                continue
                ;;
        esac

        if [[ "$head" == *'\'* ]]; then
            seg="${head//\\/}${seg:${#head}}"
            continue
        fi

        case "$head" in
            command|builtin|exec)
                seg="${seg#"$head"}"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                rest_prev=""
                while [ "$seg" != "$rest_prev" ] && [[ "$seg" == -* ]]; do
                    rest_prev="$seg"
                    tok="${seg%%[[:space:]]*}"
                    seg="${seg#*[[:space:]]}"
                    seg="${seg#"${seg%%[![:space:]]*}"}"
                    if [ "$tok" = "-a" ]; then
                        seg="${seg#*[[:space:]]}"
                        seg="${seg#"${seg%%[![:space:]]*}"}"
                    fi
                done
                continue
                ;;
        esac

        if [ "$head" = "env" ]; then
            seg="${seg#env}"
            seg="${seg#"${seg%%[![:space:]]*}"}"
            rest_prev=""
            while [ "$seg" != "$rest_prev" ] \
                && { [[ "$seg" == -* ]] || [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }; do
                rest_prev="$seg"
                tok="${seg%%[[:space:]]*}"
                seg="${seg#*[[:space:]]}"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                case "$tok" in
                    -u|-C|-S|-a|--unset|--chdir|--split-string|--block-signal|--ignore-signal|--default-signal)
                        seg="${seg#*[[:space:]]}"
                        seg="${seg#"${seg%%[![:space:]]*}"}"
                        ;;
                esac
            done
            continue
        fi

        if [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]* ]]; then
            seg="${seg#*[[:space:]]}"
            continue
        fi
    done
    GUARD_REPLY="$seg"
}

GUARD_TOKEN_NORMALIZE_LIMIT=${GUARD_TOKEN_NORMALIZE_LIMIT:-4}

_normalize_command_tokens() {
    local seg="$1"
    local out="" tok rest count=0 dq sq
    rest="${seg#"${seg%%[![:space:]]*}"}"
    while [ -n "$rest" ] && [ "$count" -lt "$GUARD_TOKEN_NORMALIZE_LIMIT" ]; do
        tok="${rest%%[[:space:]]*}"
        if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
        rest="${rest#"${rest%%[![:space:]]*}"}"
        dq="${tok//[^\"]/}"
        sq="${tok//[^\']/}"
        if [ $(( ${#dq} % 2 )) -eq 0 ] && [ $(( ${#sq} % 2 )) -eq 0 ]; then
            tok="${tok//\"/}"
            tok="${tok//\'/}"
        fi
        if [ "$count" -eq 0 ]; then
            case "$tok" in
                */*) tok="${tok##*/}" ;;
            esac
        fi
        out="${out}${out:+ }${tok}"
        count=$((count + 1))
    done
    GUARD_REPLY="${out}${rest:+ }${rest}"
}

_unwrap_code_arg() {
    local seg="$1"
    local rest inner q
    GUARD_REPLY=""

    if [[ "$seg" =~ ^([^[:space:]]*/)?eval([[:space:]]+(.*))?$ ]]; then
        rest="${BASH_REMATCH[3]}"
        rest="${rest//\"/}"
        rest="${rest//\'/}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        rest="${rest%"${rest##*[![:space:]]}"}"
        GUARD_REPLY="$rest"
        return 0
    fi

    if [[ "$seg" =~ ^([^[:space:]]*/)?(bash|sh|zsh|dash|ksh)[[:space:]]+((-[A-Za-z]+[[:space:]]+|--[A-Za-z][A-Za-z-]*[[:space:]]+)*)-[A-Za-z]*c[A-Za-z]*[[:space:]]+(.*)$ ]]; then
        rest="${BASH_REMATCH[5]}"
        q="${rest:0:1}"
        if [ "$q" = '"' ] || [ "$q" = "'" ]; then
            inner="${rest:1}"
            if [ "${inner#*"$q"}" != "$inner" ]; then
                inner="${inner%%"$q"*}"
            fi
        else
            inner="${rest%%[[:space:]]*}"
        fi
        GUARD_REPLY="$inner"
        return 0
    fi
    return 0
}

_expand_plain() {
    local raw="$1"
    local depth="${2:-4}"
    [ "$depth" -le 0 ] && return 0

    local seg normalized inner split
    split="${raw//;/$'\n'}"
    split="${split//&/$'\n'}"
    split="${split//|/$'\n'}"

    while IFS= read -r seg; do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        seg="${seg%"${seg##*[![:space:]]}"}"
        [ -z "$seg" ] && continue

        _strip_leading_wrappers "$seg"
        normalized="$GUARD_REPLY"
        [ -z "$normalized" ] && continue

        _unwrap_code_arg "$normalized"
        inner="$GUARD_REPLY"

        _normalize_command_tokens "$normalized"
        [ -n "$GUARD_REPLY" ] && printf '%s\n' "$GUARD_REPLY"

        [ -n "$inner" ] && _expand_plain "$inner" $((depth - 1))
    done < <(printf '%s\n' "$split")
}

_expand_segments() {
    local raw="$1"
    local depth="${2:-4}"
    local sanitized span

    _expand_plain "$raw" "$depth"

    _sanitize_shell_text "$raw"
    sanitized="$GUARD_REPLY"
    while IFS= read -r span; do
        [ -z "$span" ] && continue
        _expand_plain "$span" "$depth"
    done < <(_extract_subshell_spans "$sanitized")
}
