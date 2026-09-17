#!/usr/bin/env bash
#
# Shared shell-command normalization library for the PreToolUse permission
# guards (pre_tool_use__base_dir_protect.sh, pre_tool_use__permission_guard.sh).
# Sourced, never executed directly — mirrors this repo's _notify.sh convention
# of one shared implementation instead of copies drifting apart.
#
# Both guards do prefix-anchored pattern matching against pieces of a raw Bash
# tool_input.command string ("does this segment start with `git commit`",
# "does this segment start with `gh repo delete`", ...). That style of match is
# trivially defeated by wrapping or prefixing the real command:
#   - `command git commit`, `env git commit`, `\git commit`, `FOO=bar git commit`
#   - `git -c user.name=x commit`, `git --no-pager commit`,
#     `git --git-dir=X --work-tree=Y commit` (global flags before the subcommand)
#   - `eval "git commit"`, `bash -c "git commit"` (the real command is a
#     quoted argument, not the segment's own leading word)
#   - `$(git commit)`, `` `git commit` `` (the real command lives inside a
#     command substitution, possibly assigned to a variable: `X=$(git commit)`)
#
# This file gives both guards ONE implementation of "peel every one of those
# layers off, so what's left can be pattern-matched the naive way".

# -----------------------------------------------------------------------------
# _sanitize_shell_text <command-text>
#
# Strip every span of a shell command that is DATA rather than an executable
# command, so pattern heuristics cannot be tripped by prose (a commit message,
# a heredoc body). Rules, all derived from what the shell would actually
# execute:
#   - single-quoted spans  -> dropped entirely (never expanded, never executed)
#   - heredoc bodies       -> dropped entirely (fed to stdin as data)
#   - double-quoted spans  -> dropped, EXCEPT nested `$( )` / backtick
#                             substitutions, which the shell DOES execute
#                             inside double quotes and which are therefore
#                             kept (recursively)
#   - backticks            -> rewritten to `( )` so the paren heuristic sees
#                             them too
#
# ONE exception to "quoted text is data": the quoted argument of `eval` or of
# `bash|sh|zsh|dash -c` IS code — that string is handed straight back to a
# shell to execute. Those spans are kept and scanned as command text.
#
# Every dropped span leaves a space behind, so two fragments can never be
# glued into a token that looks like `git`. Command text outside quotes is
# preserved verbatim.
#
# Used by the subshell-span scanners below. The callers' own per-segment scans
# still run on the RAW command/segment, because they need quoted arguments
# (e.g. the target of `cd "/some path"`) intact.
_sanitize_shell_text() {
    local s=$1
    local n=${#s}
    local i=0
    local out=""
    # Context stack, top = last word. N top-level, S '..', D "..", P $(..), B `..`,
    # SC/DC = a '..' / ".." span that is an eval / -c argument, i.e. code not data.
    local stack="N"
    local depth="0"      # parallel stack of paren depths, one entry per P context
    local heredocs=""    # FIFO queue of heredoc delimiters awaiting their body
    local c c2 top j q delim ch rest chunk line stripped d
    # A quote opening right after this is a shell-code argument, not a literal.
    local code_arg_lead='(^|[;&|(`]|[[:space:]])(eval|(bash|sh|zsh|dash)[[:space:]]+-c)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$'

    while [ "$i" -lt "$n" ]; do
        top=${stack##* }
        c=${s:i:1}

        # --- inside a single-quoted span: pure literal text ---
        if [ "$top" = "S" ]; then
            if [ "$c" = "'" ]; then
                stack=${stack% *}
                out+=" "
                i=$((i + 1))
                continue
            fi
            # Fast-forward to the closing quote instead of walking char by char.
            rest=${s:i}
            chunk=${rest%%\'*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        # --- inside a double-quoted span: literal EXCEPT command substitutions ---
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
            # Fast-forward to the next char that could change state.
            rest=${s:i}
            chunk=${rest%%[\`\"\$\\]*}
            if [ "$chunk" = "$rest" ]; then i=$n; else i=$((i + ${#chunk})); fi
            continue
        fi

        # --- command context (N top level, P inside $( ), B inside backticks) ---
        if [ "$c" = '\' ]; then
            # Escaped char is literal; keep alphanumerics (so `\g\i\t` still reads as git),
            # blank out anything that could otherwise fake a metacharacter.
            c2=${s:i+1:1}
            case "$c2" in
                [A-Za-z0-9]) out+="$c2" ;;
                *) out+=" " ;;
            esac
            i=$((i + 2)); continue
        fi
        if [ "$c" = "'" ]; then
            if [ "$top" = "SC" ]; then stack=${stack% *}
            elif printf '%s\n' "${out##*$'\n'}" | grep -qE "$code_arg_lead"; then stack="$stack SC"
            else stack="$stack S"; fi
            out+=" "; i=$((i + 1)); continue
        fi
        if [ "$c" = '"' ]; then
            if [ "$top" = "DC" ]; then stack=${stack% *}
            elif printf '%s\n' "${out##*$'\n'}" | grep -qE "$code_arg_lead"; then stack="$stack DC"
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
        # Heredoc redirection: queue the delimiter, body is skipped at the next newline.
        # `<<<` is a here-STRING, not a heredoc, so it is excluded.
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
            [ -n "$delim" ] && heredocs="$heredocs $delim"
            out+=" "; i=$j; continue
        fi
        # Newline in command context: any queued heredoc bodies start here — drop them.
        if [ "$c" = $'\n' ]; then
            out+=$'\n'; i=$((i + 1))
            while [ -n "$heredocs" ]; do
                heredocs=${heredocs# }
                delim=${heredocs%% *}
                if [ "$delim" = "$heredocs" ]; then heredocs=""; else heredocs=${heredocs#* }; fi
                while [ "$i" -lt "$n" ]; do
                    rest=${s:i}
                    line=${rest%%$'\n'*}
                    if [ "$line" = "$rest" ]; then i=$n; else i=$((i + ${#line} + 1)); fi
                    stripped=${line#"${line%%[![:space:]]*}"}
                    stripped=${stripped%"${stripped##*[![:space:]]}"}
                    [ "$stripped" = "$delim" ] && break
                done
            done
            continue
        fi
        out+="$c"; i=$((i + 1))
    done

    printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# _extract_subshell_spans <sanitized-text>
#
# Echoes, one per line, the literal content inside every balanced `( ... )`
# group found in TEXT — including nested ones, recursively. Meant to be called
# on the OUTPUT of _sanitize_shell_text, where `$( )` and backtick spans have
# already been normalized to `( )`, so this is how a caller pulls out "the
# text of every command substitution" regardless of how deeply it's nested or
# what it's assigned to (`X=$(...)`, `` X=`...` ``, bare `$(...)`, ...).
#
# An unbalanced `(` runs to end-of-text (conservative: better to scan too much
# than miss a bypass hiding past a stray paren).
# -----------------------------------------------------------------------------
_extract_subshell_spans() {
    local s="$1"
    local n=${#s}
    local i=0
    local j depth c span
    while [ "$i" -lt "$n" ]; do
        if [ "${s:i:1}" = "(" ]; then
            depth=0
            j=$i
            while [ "$j" -lt "$n" ]; do
                c=${s:j:1}
                if [ "$c" = "(" ]; then
                    depth=$((depth + 1))
                elif [ "$c" = ")" ]; then
                    depth=$((depth - 1))
                    [ "$depth" -le 0 ] && break
                fi
                j=$((j + 1))
            done
            span=${s:i+1:j-i-1}
            printf '%s\n' "$span"
            # Recurse so a substitution nested inside another substitution is
            # surfaced too (`$(echo $(gh repo delete foo/bar))`).
            case "$span" in
                *"("*) _extract_subshell_spans "$span" ;;
            esac
            i=$((j + 1))
            continue
        fi
        i=$((i + 1))
    done
}

# -----------------------------------------------------------------------------
# _strip_leading_wrappers <segment>
#
# Peels off, repeatedly (a bypass can stack them: `command env FOO=bar \git
# commit`), every prefix that changes WHICH WORD is the real command without
# changing WHAT the command is:
#   - backslash-escape(s) on the leading word only (`\git`, `\g\i\t`)
#   - the `command` builtin, plus its own flags
#   - the `env` builtin, plus its own flags and any `VAR=value` assignments
#   - one or more bare `VAR=value` assignment prefixes
#
# Every inner loop compares against its own "did this pass change anything"
# marker before repeating, so a segment that doesn't fully parse (e.g. a
# trailing bare assignment with nothing after it) can never spin forever — it
# just stops changing and the outer loop exits.
# -----------------------------------------------------------------------------
_strip_leading_wrappers() {
    local seg="$1"
    local prev=""
    while [ "$seg" != "$prev" ]; do
        prev="$seg"
        seg="${seg#"${seg%%[![:space:]]*}"}" # ltrim

        # Backslash-escape(s) on the leading word: \git -> git, \g\i\t -> git.
        local head="${seg%%[[:space:]]*}"
        if [[ "$head" == *'\'* ]]; then
            seg="${head//\\/}${seg:${#head}}"
            continue
        fi

        # `command` builtin (with its own flags dropped, e.g. `command -p git`).
        if [[ "$seg" == command[[:space:]]* ]]; then
            seg="${seg#command}"
            seg="${seg#"${seg%%[![:space:]]*}"}"
            local cmd_prev=""
            while [ "$seg" != "$cmd_prev" ] && [[ "$seg" == -* ]]; do
                cmd_prev="$seg"
                seg="${seg#*[[:space:]]}"
                seg="${seg#"${seg%%[![:space:]]*}"}"
            done
            continue
        fi

        # `env` builtin: drop `env`, then its own flags / `VAR=value`
        # assignments that precede the real command.
        if [[ "$seg" == env[[:space:]]* ]]; then
            seg="${seg#env}"
            seg="${seg#"${seg%%[![:space:]]*}"}"
            local env_prev=""
            while [ "$seg" != "$env_prev" ] \
                && { [[ "$seg" == -* ]] || [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]* ]]; }; do
                env_prev="$seg"
                seg="${seg#*[[:space:]]}"
                seg="${seg#"${seg%%[![:space:]]*}"}"
            done
            continue
        fi

        # Bare `VAR=value` env-prefix assignment.
        if [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]* ]]; then
            seg="${seg#*[[:space:]]}"
            continue
        fi
    done
    printf '%s' "$seg"
}

# -----------------------------------------------------------------------------
# _strip_git_global_flags <segment>
#
# Only meaningful once _strip_leading_wrappers has already run. If SEGMENT
# invokes git (optionally via an absolute path to the binary), strips the
# global flags that sit between `git` and its subcommand and that a
# prefix-anchored `git (add|commit|push|...)` pattern doesn't expect to see:
# `-c key=value`, `--no-pager`, `--git-dir=`/`--git-dir <path>`,
# `--work-tree=`/`--work-tree <path>`. `-C <path>` is deliberately left
# alone — callers use it to resolve WHERE the write targets, not just whether
# one is happening.
# -----------------------------------------------------------------------------
_strip_git_global_flags() {
    local seg="$1"
    if [[ "$seg" =~ ^((/[^[:space:]]+/)?git)([[:space:]].*)?$ ]]; then
        local lead="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[3]}"
        rest="${rest#"${rest%%[![:space:]]*}"}"

        local prev=""
        while [ "$rest" != "$prev" ]; do
            prev="$rest"
            case "$rest" in
                -c[[:space:]]*)
                    rest="${rest#-c}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                    rest="${rest#*[[:space:]]}"
                    ;;
                --no-pager) rest="" ;;
                --no-pager[[:space:]]*) rest="${rest#--no-pager}" ;;
                --git-dir=*) rest="${rest#*[[:space:]]}" ;;
                --git-dir[[:space:]]*)
                    rest="${rest#--git-dir}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                    rest="${rest#*[[:space:]]}"
                    ;;
                --work-tree=*) rest="${rest#*[[:space:]]}" ;;
                --work-tree[[:space:]]*)
                    rest="${rest#--work-tree}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                    rest="${rest#*[[:space:]]}"
                    ;;
            esac
            rest="${rest#"${rest%%[![:space:]]*}"}"
        done
        printf '%s' "${lead}${rest:+ }${rest}"
    else
        printf '%s' "$seg"
    fi
}

# -----------------------------------------------------------------------------
# _unwrap_code_arg <segment>
#
# If SEGMENT is (nothing but) `eval "..."` / `eval '...'` /
# `(bash|sh|zsh|dash) -c "..."` / `... -c '...'`, echoes the quoted argument —
# the code a shell actually runs — with NO surrounding quotes. Echoes nothing
# otherwise. Callers feed the result back through segment expansion so a
# compound command inside the quotes (`eval "cmd1; gh repo delete x"`) is
# still split and matched piece by piece.
#
# Deliberately simple (no nested-quote/escape handling): the bypass shape this
# closes is a single literal quoted string, which is what every reported case
# looks like. A quoted argument built from expressions/expansions is opaque to
# a static hook either way.
# -----------------------------------------------------------------------------
_unwrap_code_arg() {
    local seg="$1"
    if [[ "$seg" =~ ^eval[[:space:]]+\"(.*)\"[[:space:]]*$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$seg" =~ ^eval[[:space:]]+\'(.*)\'[[:space:]]*$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$seg" =~ ^(bash|sh|zsh|dash)[[:space:]]+-c[[:space:]]+\"(.*)\"[[:space:]]*$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    elif [[ "$seg" =~ ^(bash|sh|zsh|dash)[[:space:]]+-c[[:space:]]+\'(.*)\'[[:space:]]*$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# -----------------------------------------------------------------------------
# _expand_segments <raw-command> [max-depth]
#
# The one entry point most callers need. Echoes, one per line, every segment a
# pattern-matching rule should independently consider:
#   - each `;`/`&`/`|`/newline-split top-level piece of RAW, normalized via
#     _strip_leading_wrappers
#   - the unwrapped body of any `eval`/`*sh -c` piece, itself expanded
#     recursively (so a compound command inside the quotes is split too)
#   - the content of every `$( )`/backtick span anywhere in RAW (via the
#     sanitizer + span extractor above), also expanded recursively
#
# Depth-bounded (default 4) so pathological nesting can't recurse forever;
# each level operates on a strictly shorter string, so this always terminates.
# Duplicates across the different expansion paths are expected and harmless —
# callers only care whether ANY returned segment matches their pattern.
# -----------------------------------------------------------------------------
_expand_segments() {
    local raw="$1"
    local depth="${2:-4}"
    [ "$depth" -le 0 ] && return 0

    local seg normalized inner
    while IFS= read -r seg; do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        seg="${seg%"${seg##*[![:space:]]}"}"
        [ -z "$seg" ] && continue

        normalized="$(_strip_leading_wrappers "$seg")"
        [ -n "$normalized" ] && printf '%s\n' "$normalized"

        inner="$(_unwrap_code_arg "$normalized")"
        [ -n "$inner" ] && _expand_segments "$inner" $((depth - 1))
    done < <(printf '%s\n' "$raw" | tr ';&|' '\n')

    local sanitized span
    sanitized="$(_sanitize_shell_text "$raw")"
    while IFS= read -r span; do
        [ -z "$span" ] && continue
        _expand_segments "$span" $((depth - 1))
    done < <(_extract_subshell_spans "$sanitized")
}
