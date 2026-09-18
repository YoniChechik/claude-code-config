#!/usr/bin/env bash

# Base directory for the CI watcher lock/pid files and the session-name
# sidecar. Defaults to /tmp; overridable (mainly for tests) so these paths can
# be redirected without touching the real /tmp.
: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"

# --- Session name (the /session-name skill's per-session label) --------------
# THE single implementation of the sanitize-and-cap contract every session-name
# site shares: this file, scripts/status_line.sh (which sources this file), and
# skills/session-name/SKILL.md (which also sources this file). Do not re-inline
# a copy anywhere — the whole point is that there is exactly one of these.
#
# Contract: drop C0 control bytes (0x00-0x1F, which covers raw ESC/BEL/newline/
# tab), DEL (0x7F), C1 (0x80-0x9F), and the backslash character; trim
# leading/trailing whitespace; cap at 35 Unicode CODEPOINTS — never a bash
# byte-slice like ${name:0:35}, which can split a multi-byte UTF-8 character.
#
# Backslash is stripped because stripping raw control bytes alone is NOT
# enough: any renderer that expands backslash escapes (printf '%b', echo -e)
# turns purely-printable text such as `\033]0;PWNED\007` back into a genuine
# escape sequence. Removing 0x5C closes that at the source, independently of
# what each consumer does at print time.
#
# The value reaches python on STDIN as raw bytes, never as an argv string.
# argv would (a) exceed ARG_MAX on an oversized sidecar file, which aborts the
# caller, and (b) decode invalid UTF-8 with surrogateescape, yielding lone
# surrogates that raise UnicodeEncodeError on output. Decoding the bytes here
# with errors="ignore" drops malformed bytes cleanly instead.
_sanitize_and_cap() {
    local raw="$1"
    # Fast path, zero forks: a short plain-ASCII label carrying no backslash
    # and no edge whitespace is already in its final form. status_line.sh calls
    # this on a ~1/second poll, so avoiding a python start-up here is worth the
    # extra branch. `local LC_ALL=C` makes the range a pure BYTE test (and is
    # restored on return), so every multi-byte or invalid byte takes the slow
    # path below rather than being wrongly waved through.
    local LC_ALL=C
    case "$raw" in
        *[!\ -~]* | *\\* | " "* | *" ") ;;
        *) if [ "${#raw}" -le 35 ]; then printf '%s' "$raw"; return 0; fi ;;
    esac
    # Bytes in on stdin, bytes out on stdout: neither direction goes through a
    # locale-dependent text encoder, so the LC_ALL=C set above for the fast-path
    # test cannot make a multi-byte result unprintable.
    printf '%s' "$raw" | python3 -c '
import sys
s = sys.stdin.buffer.read().decode("utf-8", "ignore")
s = "".join(
    ch for ch in s
    if not (ord(ch) < 0x20 or ord(ch) == 0x7F or 0x80 <= ord(ch) <= 0x9F or ch == "\\")
)
sys.stdout.buffer.write(s.strip()[:35].encode("utf-8"))
' 2>/dev/null || true
}

# Echo the sanitized+capped session name stored for session id $1 (the
# `/session-name` skill's sidecar at
# "${CLAUDE_NOTIFY_TMP_DIR}/session_name_<session_id>").
#
# NO fallback of any kind: a missing session id, a missing/empty/non-regular
# sidecar file, or a name that sanitizes down to nothing all echo nothing
# (empty, exit 0). The caller must then skip the title/segment entirely rather
# than substituting a git branch, a worktree name, or any other value.
_session_name_read() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 0
    local path="${CLAUDE_NOTIFY_TMP_DIR}/session_name_${session_id}"
    # Regular files only. The path is predictable and lives in a shared /tmp,
    # so a FIFO or socket planted there would block `cat` (and with it the
    # 1s-interval status-line poll) forever.
    [ -f "$path" ] || return 0
    # Byte cap taken BEFORE the value is handed to anything else, so a runaway
    # or corrupt multi-megabyte sidecar degrades to a truncated name instead of
    # being slurped into memory on every poll. 512 bytes is far more than 35
    # codepoints can ever need (4 bytes maximum per codepoint).
    local raw
    raw=$(head -c 512 "$path" 2>/dev/null || true)
    [ -n "$raw" ] || return 0
    _sanitize_and_cap "$raw"
}

# --- CI watcher key components ----------------------------------------------
# Every ci_watch_once.sh watcher's /tmp files are keyed on
# "<component>_<kind>_<slug>-<KEY>", where <slug> is the readable branch slug
# below and <KEY> is _ci_watch_key's identity hash. The hash, not the slug, is
# what makes the key unique — folding owner/repo into it is what stops two
# worktrees of DIFFERENT repos that share a branch name from colliding.

# The readable branch slug: every BYTE outside [A-Za-z0-9._-] becomes "_",
# capped at 40 bytes. LC_ALL=C forces tr and cut into byte mode so a non-ASCII
# branch name can't desync a codepoint count from a byte count.
_ci_slug() {
    # The $( ) strips cut's line terminator, so the slug carries no trailing
    # newline for a caller that does not wrap it in a command substitution of
    # its own. tr has already turned any real newline into "_".
    printf '%s' "$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-40)"
}

# --- CI watcher key (the one-shot ci_watch_once.sh watchers) ----------------
# The GLOBAL, session-independent identity of one watched branch:
#   KEY = first 10 hex chars of sha256("<owner>/<repo>#<branch>")
# A one-shot watcher is keyed on (owner/repo, branch, kind) across every
# session and terminal on the machine, not per session.
#
# It returns ONLY the hash. It takes no `kind` argument: each caller composes
# its own filename as "<component>_<kind>_<slug>-<KEY>", where <slug> is
# _ci_slug "$branch". One shared hash function; kind-scoping lives in the
# filename convention, never in duplicated hashing logic.
#
# Args: <owner/repo> <branch>.
_ci_watch_key() {
    local name_with_owner="$1" branch="$2"
    local identity_hash
    identity_hash=$(printf '%s' "${name_with_owner}#${branch}" \
        | shasum -a 256 | cut -c1-10)
    # Validate rather than trust: shasum is a perl script, not a coreutils
    # binary, and is absent on many minimal images. An empty hash would build a
    # key no watcher ever owns, so every lock, eviction and stop would silently
    # target files that do not exist.
    case "$identity_hash" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *)
            echo "Error: could not compute the ci watcher identity hash (is shasum installed?)." >&2
            return 1
            ;;
    esac
    printf '%s' "$identity_hash"
}
