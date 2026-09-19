#!/usr/bin/env bash
#
# Shared shell-command normalization library for the PreToolUse permission
# guards (pre_tool_use__base_dir_protect.sh, pre_tool_use__permission_guard.sh)
# and the PermissionRequest auto-allow guard (permission_request.sh).
# Sourced, never executed directly — mirrors this repo's _notify.sh convention
# of one shared implementation instead of copies drifting apart.
#
# The guards do prefix-anchored pattern matching against pieces of a raw Bash
# tool_input.command string ("does this segment start with `git commit`",
# "does this segment start with `gh repo delete`", ...). That style of match is
# trivially defeated by wrapping or prefixing the real command:
#   - `command git commit`, `builtin git commit`, `env git commit`,
#     `exec git commit`, `\git commit`, `FOO=bar git commit`
#   - `/usr/bin/gh repo delete`, `g"h" repo delete`, `gh re""po delete`
#   - `git -c user.name=x commit`, `git --paginate commit`
#   - `eval "git commit"`, `bash -lc "git commit"`,
#     `bash -c "git commit" trailing-argv`
#   - `$(git commit)`, `` `git commit` `` (a command substitution, possibly
#     assigned to a variable: `X=$(git commit)`)
#   - `{ gh repo delete x; }`, `if true; then gh repo delete x; fi`
#   - a heredoc with an UNQUOTED delimiter, whose body still runs `$( )`
#
# This file gives every guard ONE implementation of "peel each of those layers
# off, so what's left can be pattern-matched the naive way".
#
# PERFORMANCE CONTRACT
# --------------------
# These functions run on EVERY Bash tool call, inside a 60s hook budget. A
# guard that takes too long is not merely slow: a timed-out hook produces no
# decision, which the harness reads as "allow". Adversarial input must
# therefore never be able to make the scan expensive. Two rules follow:
#   1. No forks in per-segment code. Helpers return through the GUARD_REPLY
#      global instead of stdout, because `x=$(f ...)` forks a subshell for
#      every call; `[[ ... ]]`/`case` replace every `echo | grep` and `sed`.
#   2. No forks in per-segment code, per rule 1 above.

# -----------------------------------------------------------------------------
# Path canonicalization, shared by permission_request.sh (is this command
# confined to .claude/?) and pre_tool_use__base_dir_protect.sh (is this file
# inside a worktree?).
#
# Matching the RAW, unresolved text is a path-traversal bypass:
# `.../.claude/../../etc/hosts` contains the substring "/.claude/" while
# actually pointing well outside it, and
# `<repo>/.claude/worktrees/x/../../../README.md` matches the worktree pattern
# while actually pointing at the base repo.
#
# `~`/`$HOME`/`$CLAUDE_CONFIG_DIR` are expanded textually first, since a hook
# only ever sees the command/path as literal text, never a real shell's
# expansion of it.
#
# Uses python3's os.path.realpath rather than the platform `realpath`/
# `readlink -f`: BSD realpath (macOS) refuses to resolve a path unless EVERY
# component already exists on disk, which breaks the common case of a Write to
# a file that does not exist yet. os.path.realpath resolves symlinks where it
# can and lexically normalizes the rest, existing or not.
#
# KNOWN LIMIT (accepted, not fixable in a hook): this is a check-time answer.
# A symlink swapped between this check and the tool's own open() would defeat
# it. Closing that would need the check and the write to share one file
# descriptor, which a PreToolUse hook cannot do.
# -----------------------------------------------------------------------------

# Expand ~ / $HOME / $CLAUDE_CONFIG_DIR prefixes into GUARD_REPLY. No fork.
_guard_expand_home() {
    local token="$1"
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # `~` held in a variable so the case patterns below are unmistakably
    # LITERAL tildes (a quoted `~` in a pattern is exactly what is wanted here:
    # the hook receives the character, never a shell's expansion of it).
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

# _resolve_path <base-dir> <token> -> canonical absolute path on stdout.
# One python3 fork. Prefer _resolve_paths below when resolving several tokens.
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

# _resolve_paths <base-dir> <token>... -> one canonical path per input token,
# in order, on stdout. ONE python3 fork for the whole batch, which is what
# keeps the per-command path audit in permission_request.sh cheap.
_resolve_paths() {
    local base="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    local -a expanded=()
    local t
    for t in "$@"; do
        _guard_expand_home "$t"
        expanded+=("$GUARD_REPLY")
    done
    python3 -c '
import os, sys
base = sys.argv[1]
for p in sys.argv[2:]:
    if not os.path.isabs(p):
        p = os.path.join(base, p)
    print(os.path.realpath(p))
' "$base" "${expanded[@]}" 2>/dev/null
}

# _is_under_claude_dir <already-canonicalized-path>
#
# Safe to substring-match here BECAUSE the path has already had every
# `.`/`..`/symlink collapsed — there is no traversal token left to hide behind.
_is_under_claude_dir() {
    case "$1" in
        */.claude/*|*/.claude) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# _ws_collapse <text> -> GUARD_REPLY
#
# Collapses every run of whitespace (space, tab, newline) to a single space and
# trims the ends, so a rule can test "does this segment start with `gh repo
# delete`" with a plain `==` glob instead of a forked `grep -E`.
# -----------------------------------------------------------------------------
_ws_collapse() {
    local s="$1"
    s="${s//$'\t'/ }"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    # Squeeze runs of spaces. Each pass halves the longest run, so this
    # terminates in log(n) passes and never walks the string character by
    # character.
    while [ "${s#*  }" != "$s" ]; do
        s="${s//  / }"
    done
    s="${s# }"
    s="${s% }"
    GUARD_REPLY="$s"
}

# -----------------------------------------------------------------------------
# _sanitize_shell_text <command-text> -> GUARD_REPLY
#
# Strip every span of a shell command that is DATA rather than an executable
# command, so pattern heuristics cannot be tripped by prose (a commit message,
# a heredoc body). Rules, all derived from what the shell would actually
# execute:
#   - single-quoted spans  -> dropped entirely (never expanded, never executed)
#   - QUOTED-delimiter heredoc bodies (<<'EOF' / <<"EOF")
#                          -> dropped entirely (inert data on stdin)
#   - UNQUOTED-delimiter heredoc bodies (<<EOF)
#                          -> prose dropped, but every `$( )`/backtick
#                             substitution inside is KEPT, because the shell
#                             really does run those before feeding the body to
#                             stdin. Dropping the whole body was a real bypass:
#                             `cat <<EOF` / `$(git commit -m x)` / `EOF`.
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
# The callers' own per-segment scans still run on the RAW command/segment,
# because they need quoted arguments (e.g. the target of `cd "/some path"`)
# intact.
# -----------------------------------------------------------------------------
_sanitize_shell_text() {
    local s=$1
    local n=${#s}
    local i=0
    local out=""
    # Context stack, top = last word. N top-level, S '..', D "..", P $(..), B `..`,
    # SC/DC = a '..' / ".." span that is an eval / -c argument, i.e. code not data.
    local stack="N"
    local depth="0"      # parallel stack of paren depths, one entry per P context
    local heredocs=""    # FIFO queue of "<Q|U>:<delimiter>" awaiting their body
    local c c2 top j q delim ch rest chunk line stripped d entry lead
    # A quote opening right after this is a shell-code argument, not a literal.
    local code_arg_lead='(^|[;&|(`]|[[:space:]])(eval|(bash|sh|zsh|dash|ksh)[[:space:]]+-[A-Za-z]*c[A-Za-z]*)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$'

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
        # Heredoc redirection: queue the delimiter AND whether it was quoted.
        # A quoted delimiter (<<'EOF') makes the body inert; an unquoted one
        # (<<EOF) still performs command/parameter substitution inside it.
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
            if [ -n "$delim" ]; then
                if [ -n "$q" ]; then heredocs="$heredocs Q:$delim"; else heredocs="$heredocs U:$delim"; fi
            fi
            out+=" "; i=$j; continue
        fi
        # Newline in command context: any queued heredoc bodies start here.
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
                    # Unquoted delimiter: the body's substitutions still run, so
                    # keep them (and only them) as command text.
                    if [ "$q" = "U" ]; then
                        _guard_collect_substitutions "$line"
                        [ -n "$GUARD_REPLY" ] && out+=" $GUARD_REPLY "
                    fi
                done
            done
            continue
        fi
        # Ordinary command text. Copy the whole run up to the next character
        # that could change state, instead of one character per loop pass:
        # `${s:i:1}` costs O(len) in bash, so a per-character walk over a long
        # command was quadratic (a 16 KB command took ~3.7s on its own).
        rest=${s:i}
        chunk=${rest%%[\\\'\"\`\$()\<$'\n']*}
        if [ "$chunk" = "$rest" ]; then
            out+="$rest"; i=$n
        elif [ -z "$chunk" ]; then
            # Current char is "interesting" but reached here anyway (a lone `<`).
            out+="$c"; i=$((i + 1))
        else
            out+="$chunk"; i=$((i + ${#chunk}))
        fi
    done

    GUARD_REPLY="$out"
}

# _guard_collect_substitutions <text> -> GUARD_REPLY
#
# Pulls every `$( ... )` and `` ` ... ` `` span out of TEXT and returns them
# concatenated as `( ... )` groups, dropping everything around them. Used for
# unquoted-heredoc bodies: the prose stays data, the substitutions become
# command text the span scanner can see.
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

# -----------------------------------------------------------------------------
# _extract_subshell_spans <sanitized-text>
#
# Echoes, one per line, the literal content inside every balanced `( ... )`
# group found in TEXT — including nested ones. Meant to be called on the OUTPUT
# of _sanitize_shell_text, where `$( )` and backtick spans have already been
# normalized to `( )`, so this is how a caller pulls out "the text of every
# command substitution" regardless of how deeply it's nested or what it's
# assigned to (`X=$(...)`, `` X=`...` ``, bare `$(...)`, ...).
#
# SINGLE PASS, stack based. The previous implementation recursed on each
# extracted substring, so every nesting level re-scanned all the text below it:
# depth 8 took ~28s, which alone was enough to push the hook past its timeout
# and make the harness allow the call. This version touches each character once.
#
# An unbalanced `(` runs to end-of-text (conservative: better to scan too much
# than miss a bypass hiding past a stray paren).
# -----------------------------------------------------------------------------
_extract_subshell_spans() {
    local s="$1"
    local n=${#s}
    local i=0
    local c top rest chunk
    # Stack of open-paren offsets, as a space-separated string (bash 3.2 has no
    # cheap array pop, and the string form keeps this allocation-free).
    local starts=""
    while [ "$i" -lt "$n" ]; do
        # Jump straight to the next paren instead of inspecting every character
        # (`${s:i:1}` is O(len), so a per-character walk is quadratic).
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
    # Any still-open paren: treat the rest of the text as its span.
    while [ -n "$starts" ]; do
        top=${starts##* }
        starts=${starts% *}
        printf '%s\n' "${s:top+1}"
    done
}

# -----------------------------------------------------------------------------
# _strip_leading_wrappers <segment> -> GUARD_REPLY
#
# Peels off, repeatedly (a bypass can stack them: `command env FOO=bar \git
# commit`), every prefix that changes WHICH WORD is the real command without
# changing WHAT the command is:
#   - shell grammar keywords that introduce a command body: `{`, `}`, `(`, `)`,
#     `!`, `if`, `then`, `elif`, `else`, `fi`, `while`, `until`, `do`, `done`,
#     `for`, `case`, `esac`, `in`, `time`, `coproc`
#   - backslash-escape(s) on the leading word only (`\git`, `\g\i\t`)
#   - the `command` / `builtin` / `exec` builtins, plus their own flags
#   - the `env` builtin, plus its own flags (including the ones that take a
#     SEPARATE argument, e.g. `env -u FOO gh ...`) and any `VAR=value`
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
    local head rest_prev tok
    while [ "$seg" != "$prev" ]; do
        prev="$seg"
        seg="${seg#"${seg%%[![:space:]]*}"}" # ltrim

        # Shell grammar punctuation that opens/closes a command body. Peeled so
        # `{ gh repo delete x; }` is scanned as `gh repo delete x`.
        case "$seg" in
            '{'|'}'|'('|')'|'!') seg=""; continue ;;
            '{'[[:space:]]*|'}'[[:space:]]*|'('[[:space:]]*|')'[[:space:]]*|'!'[[:space:]]*)
                seg="${seg:1}"; continue ;;
        esac

        head="${seg%%[[:space:]]*}"

        # Shell grammar keywords. Dropping the keyword exposes the command body
        # that follows it on the same segment (`then gh repo delete x`).
        case "$head" in
            if|then|elif|else|fi|while|until|do|done|for|case|'esac'|in|time|coproc)
                if [ "$head" = "$seg" ]; then seg=""; else seg="${seg#*[[:space:]]}"; fi
                continue
                ;;
        esac

        # Backslash-escape(s) on the leading word: \git -> git, \g\i\t -> git.
        if [[ "$head" == *'\'* ]]; then
            seg="${head//\\/}${seg:${#head}}"
            continue
        fi

        # `command` / `builtin` / `exec` builtins, with their own flags dropped
        # (e.g. `command -p git`, `exec -a name git`).
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
                    # `exec -a NAME` consumes a following argument.
                    if [ "$tok" = "-a" ]; then
                        seg="${seg#*[[:space:]]}"
                        seg="${seg#"${seg%%[![:space:]]*}"}"
                    fi
                done
                continue
                ;;
        esac

        # `env` builtin: drop `env`, then its own flags / `VAR=value`
        # assignments that precede the real command. Several env flags take a
        # SEPARATE argument; skipping only the flag left the argument sitting
        # in command position (`env -u FOO gh ...` read as the command `FOO`).
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

        # Bare `VAR=value` env-prefix assignment.
        if [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]* ]]; then
            seg="${seg#*[[:space:]]}"
            continue
        fi
    done
    GUARD_REPLY="$seg"
}

# -----------------------------------------------------------------------------
# _normalize_command_tokens <segment> -> GUARD_REPLY
#
# Two normalizations that make a naive prefix match see the real command name:
#
#   1. Drop the leading directory of the command word: `/usr/bin/gh repo delete`
#      and `./bin/git commit` become `gh repo delete` / `git commit`. Only git
#      had this treatment before, via its own pattern.
#
#   2. Remove quote characters INSIDE a token, so `g"h"` reads as `gh` and
#      `gh re""po` as `gh repo` — quote-concatenation inside one word is a real
#      bypass of a `^gh repo delete` match.
#
# Rule 2 is deliberately narrow, because blanket quote removal would turn the
# PROSE of `git commit -m "note about gh repo delete"` into bare command text:
#   - only the first GUARD_TOKEN_NORMALIZE_LIMIT tokens are considered (a
#     command name and its subcommands, never a long message body), and
#   - only tokens whose quotes are BALANCED within the token are rewritten, so
#     `"note` (the opening word of a quoted sentence) is left alone.
# -----------------------------------------------------------------------------
GUARD_TOKEN_NORMALIZE_LIMIT=${GUARD_TOKEN_NORMALIZE_LIMIT:-4}

_normalize_command_tokens() {
    local seg="$1"
    local out="" tok rest count=0 dq sq
    rest="${seg#"${seg%%[![:space:]]*}"}"
    while [ -n "$rest" ] && [ "$count" -lt "$GUARD_TOKEN_NORMALIZE_LIMIT" ]; do
        tok="${rest%%[[:space:]]*}"
        if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
        rest="${rest#"${rest%%[![:space:]]*}"}"
        # Balanced quotes inside one token -> concatenation, not a quoted span.
        dq="${tok//[^\"]/}"
        sq="${tok//[^\']/}"
        if [ $(( ${#dq} % 2 )) -eq 0 ] && [ $(( ${#sq} % 2 )) -eq 0 ]; then
            tok="${tok//\"/}"
            tok="${tok//\'/}"
        fi
        # Command word only: strip its directory component.
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

# -----------------------------------------------------------------------------
# _unwrap_code_arg <segment> -> GUARD_REPLY (empty when there is nothing to
# unwrap)
#
# If SEGMENT runs a shell over a string — `eval ...`, `bash -c "..."`,
# `sh -lc '...'`, `zsh -ic "..."`, with or without trailing positional args —
# returns that string, the code a shell actually runs, with its outer quotes
# removed. Callers feed the result back through segment expansion so a compound
# command inside the quotes (`eval "cmd1; gh repo delete x"`) is still split
# and matched piece by piece.
#
# Three bypasses this closes versus an end-anchored `-c "(.*)"$` match:
#   - trailing argv:  bash -c "gh repo delete x" sentinel   ($0 after the code)
#   - combined flags: bash -lc "gh repo delete x"
#   - a path:         /bin/bash -c "gh repo delete x"
#
# Deliberately simple about nested quotes: it takes the code up to the FIRST
# matching quote, which is conservative (a shorter, still-scanned fragment)
# rather than permissive. A quoted argument built from expansions is opaque to
# a static hook either way.
# -----------------------------------------------------------------------------
_unwrap_code_arg() {
    local seg="$1"
    local rest inner q
    GUARD_REPLY=""

    # `eval` concatenates ALL of its arguments and runs the result, so
    # everything after the keyword is code; strip the quote characters.
    if [[ "$seg" =~ ^([^[:space:]]*/)?eval([[:space:]]+(.*))?$ ]]; then
        rest="${BASH_REMATCH[3]}"
        rest="${rest//\"/}"
        rest="${rest//\'/}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        rest="${rest%"${rest##*[![:space:]]}"}"
        GUARD_REPLY="$rest"
        return 0
    fi

    # `<shell> [flags] -<...>c<...> <code> [argv...]`
    if [[ "$seg" =~ ^([^[:space:]]*/)?(bash|sh|zsh|dash|ksh)[[:space:]]+((-[A-Za-z]+[[:space:]]+|--[A-Za-z][A-Za-z-]*[[:space:]]+)*)-[A-Za-z]*c[A-Za-z]*[[:space:]]+(.*)$ ]]; then
        rest="${BASH_REMATCH[5]}"
        q="${rest:0:1}"
        if [ "$q" = '"' ] || [ "$q" = "'" ]; then
            inner="${rest:1}"
            # Up to the first matching quote — everything after it is argv.
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

# -----------------------------------------------------------------------------
# _expand_segments <raw-command> [max-depth]
#
# The one entry point most callers need. Echoes, one per line, every segment a
# pattern-matching rule should independently consider:
#   - each `;`/`&`/`|`/newline-split top-level piece of RAW, with wrappers,
#     grammar keywords, directory prefixes and in-token quotes normalized away
#   - the unwrapped body of any `eval`/`*sh -c` piece, itself expanded
#     recursively (so a compound command inside the quotes is split too)
#   - the content of every `$( )`/backtick span anywhere in RAW (via the
#     sanitizer + span extractor above), also expanded recursively
#
# Depth-bounded (default 4) so pathological nesting can't recurse forever; each
# level operates on a strictly shorter string, so this always terminates.
# Duplicates across the different expansion paths are expected and harmless —
# callers only care whether ANY returned segment matches their pattern.
#
# Fork-free per segment: the split uses parameter expansion instead of `tr`,
# and every helper returns through GUARD_REPLY instead of a `$( )` subshell.
#
# The sanitize + span-extract pass runs EXACTLY ONCE on the whole command.
# _extract_subshell_spans already enumerates every nested span in a single
# walk, so re-running the whole pipeline on each extracted span (what the
# previous version did) only re-derived spans it already had — at a cost that
# grew like span_count^expansion_depth. Depth 32 took 16s that way; it is now
# linear in the number of spans.
# -----------------------------------------------------------------------------

# _expand_plain <text> [max-depth]
# Splits TEXT into separator-delimited segments, normalizes each one, and
# recurses ONLY into an unwrapped `eval`/`-c` code argument (which the span
# extractor cannot see into, because the code lives inside quotes).
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

        # The code argument is read BEFORE token normalization, because that
        # step strips the very quotes that delimit it.
        _unwrap_code_arg "$normalized"
        inner="$GUARD_REPLY"

        _normalize_command_tokens "$normalized"
        [ -n "$GUARD_REPLY" ] && printf '%s\n' "$GUARD_REPLY"

        [ -n "$inner" ] && _expand_plain "$inner" $((depth - 1))
    done <<<"$split"
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
