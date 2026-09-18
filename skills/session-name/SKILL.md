---
name: "session-name"
description: "Assign or update a short label describing what this Claude Code session is currently doing, stored in a per-session sidecar file so status_line.sh and the cmux workspace title can show it; also triggers Claude Code's native /rename inside cmux so the terminal title, /resume picker, and Remote Control app pick up the name too"
argument-hint: "[optional forced name]"
---

Sets (or re-sets) the current session's display name: a short, human-readable
label stored in a per-session sidecar file. `status_line.sh` and the cmux
workspace title read only this file — there is no fallback to the
branch/worktree name. When running inside cmux, this skill additionally
triggers Claude Code's own native `/rename` (Step 9) — a separate naming
layer covering the terminal title, the `/resume` picker, and the Remote
Control app. Safe to re-run any number of times in one session as the topic
drifts; each run is a fresh decision, not a one-time setup step.

## Step 1: Guard the session id

```bash
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot set a session name." >&2
    exit 1
fi
```

Every file this skill touches is keyed on this exact env var, matching the
convention `ci-watcher` and `_notify.sh` already use for their own
`/tmp/*_<slot>` files.

## Step 2: Load the shared helpers and read the currently-stored name

`scripts/_notify.sh` holds the ONE implementation of this feature's
sanitize-and-cap contract. Source it and use it — never re-inline a copy of
the sanitize logic here, in `status_line.sh`, or anywhere else.

```bash
source ~/.claude/scripts/_notify.sh
STORED_NAME=$(_session_name_read "$CLAUDE_CODE_SESSION_ID")
```

`_session_name_read` returns the stored name already sanitized and capped, and
returns empty for every "no usable name" case: missing file, empty file, a
non-regular file, or content that sanitizes down to nothing.

## Step 3: The sanitize-and-cap contract

`_sanitize_and_cap "<text>"` (from the same sourced file) is the one contract
every read site and write site shares. It:

- Strips C0 control bytes (`0x00-0x1F`, which covers raw ESC, BEL, newline and
  tab), DEL (`0x7F`), and C1 (`0x80-0x9F`).
- Strips the backslash character. Raw control bytes are not the only threat:
  any renderer that expands backslash escapes turns purely-printable text like
  `\033]0;PWNED\007` back into a genuine terminal escape sequence, so the
  backslash is removed at the source.
- Drops invalid UTF-8 bytes instead of crashing on them.
- Trims leading and trailing whitespace.
- Caps at 35 Unicode **codepoints** — never a bash byte-slice like
  `${name:0:35}`, which can split a multi-byte UTF-8 character mid-sequence.

Run every candidate name — forced argument or auto-proposed — through it
before comparing or writing.

## Step 4: Determine the proposed name

- If `$ARGUMENTS` is non-empty, sanitize+cap it (Step 3) — this is the
  proposed name, forced by the caller. No exemption from sanitize/cap rules
  just because it was explicitly given.
- Otherwise, look at the current conversation, branch name, and task at hand,
  and decide a short (aim well under 35 codepoints) label that describes what
  this session is currently doing. Sanitize+cap it the same way (Step 3) even
  though it's model-generated — the cap and strip rules apply universally,
  not only to user-supplied text.

If the sanitized proposed name is **empty** (an all-whitespace, all-control-byte
or all-backslash candidate), stop here: report the error to the user and write
nothing. An empty sidecar means "no name" to both readers, so writing one would
silently clear the status-line segment and blank the cmux workspace title instead of
naming the session.

```bash
if [[ -z "$PROPOSED_NAME" ]]; then
    echo "Error: the proposed session name is empty after sanitizing; nothing written." >&2
    exit 1
fi
```

## Step 5: No-op check

Compare the sanitized proposed name (Step 4) to the stored name (Step 2, which
is already sanitized). If they are identical:

- Make **no write**. Do not touch the sidecar file, do not re-emit the workspace title
  escape.
- Tell the user the current session name still fits and stop here. This is a
  first-class, correct outcome — renaming is not mandatory just because this
  skill ran.

Otherwise, continue to Step 6.

## Step 6: Mandatory orchestrator confirmation (subagents only)

Decide whether *you*, the agent currently executing this skill, are the
top-level orchestrator (the agent talking directly to the user in this
session) or a subagent — including a sub-subagent nested at any depth,
launched via the `Agent` tool.

- **You are a subagent (any depth):** you must NOT write the sidecar file
  unilaterally. Load `SendMessage` if not already available
  (`ToolSearch` query `select:SendMessage`), then call
  `SendMessage(to: "main", message: "<proposed name> — <brief reason>")` and
  wait for `main`'s reply. Treat the reply as either a confirmation (proceed
  with the proposed name) or an adjusted name (use that name instead, still
  subject to Step 3's sanitize+cap). Only after this reply do you proceed to
  Step 7. The one caveat: `SendMessage` cannot bypass a permission prompt
  blocking you — the user's approve/deny is still required first if one is in
  the way.
- **You are the top-level orchestrator:** no ping needed. Decide and proceed
  directly to Step 7, the same way `create-worktree` decides a feature name
  from a description without asking anyone else first.

## Step 7: Write the sidecar file atomically

Never a direct `>` truncate-then-write — `status_line.sh` polls this file on
a 1-second interval and must never observe a half-written or empty file
mid-update.

Every step is checked, and the temp file is removed on any failure — reporting
a new name to the user after a write that did not land is worse than reporting
the failure.

```bash
NAME="<final sanitized+capped name from Step 4/6>"
DEST="${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_${CLAUDE_CODE_SESSION_ID}"
tmp=$(mktemp "${CLAUDE_NOTIFY_TMP_DIR:-/tmp}/session_name_XXXXXX") || {
    echo "Error: could not create the temp file for the session name." >&2
    exit 1
}
if ! printf '%s' "$NAME" > "$tmp" || ! mv -f "$tmp" "$DEST"; then
    rm -f "$tmp"
    echo "Error: could not store the session name at $DEST." >&2
    exit 1
fi
```

## Step 8: Rename the cmux workspace

Terminal OSC 0/2 title escapes have no effect on cmux's sidebar (verified
empirically — cmux does not read them), so the workspace title is set through
cmux's own CLI instead: `cmux rename-workspace`. It defaults to the current
workspace via `$CMUX_WORKSPACE_ID` (auto-set in every cmux terminal), so no
explicit `--workspace` flag is needed here.

When `CMUX_WORKSPACE_ID` is unset (not running inside cmux — e.g. a plain
terminal or an unrelated wrapper), skip the rename silently rather than
erroring: the sidecar file written in Step 7 is still the source of truth for
`status_line.sh`, so the session name is not lost, only the cmux sidebar
label.

```bash
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    cmux rename-workspace -- "$NAME" 2>/dev/null || true
fi
```

Note: cmux's opt-in `automation.workspaceAutoNaming` setting (off by default;
confirmed unset in this environment) drives its OWN turn-end AI naming of
workspaces for supported agents including Claude Code. That is a separate,
automatic mechanism gated on a live socket setting — this skill's explicit
rename is independent of it and runs regardless of whether that setting is
ever turned on.

## Step 9: Trigger Claude Code's native `/rename` (cmux only)

The sidecar file (Step 7) and cmux workspace title (Step 8) are a
project-local naming layer — they do not touch Claude Code's own native
session name (`~/.claude/sessions/<pid>.json`'s `name` field), which drives
the terminal title, the `/resume` picker, and the Remote Control companion
app. That native field has no exposed tool or file-edit path: editing the
JSON file directly, or appending a fabricated `ai-title` record to the
session's transcript JSONL, does NOT propagate to Remote Control (confirmed
empirically) — only the real `/rename` command does, because it also pushes
the change live over the session's existing connection to Anthropic's
backend.

When running inside cmux (`$CMUX_SURFACE_ID` is set), `cmux send` delivers
text to this session's own terminal surface exactly as if it were typed —
cmux is the pty's actual owner, so this is not a hack, it is the documented
path (`cmux send --help`). Use it to fire the real native rename:

```bash
if [[ -n "${CMUX_SURFACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    cmux send -- "/rename ${NAME}\n"
fi
```

Confirmed empirically (2026-09-18): this updates `sessions/<pid>.json`'s
`name` / `nameSource:"user"` / `formerNames`, the `/resume` picker's title,
and the Remote Control app's displayed name — all three at once, even
mid-turn while the orchestrator is still busy. Skip silently when
`CMUX_SURFACE_ID` is unset (not running inside cmux) — there is no other
known path to the native field from inside a session.

Do not attempt this via raw tty `TIOCSTI` injection: macOS restricts
`TIOCSTI` to the tty's session leader (the `claude` process itself) or root —
a sibling process gets `EPERM` even with read/write permission on the device
file, confirmed empirically.

## Step 10: Report

Tell the user the session name that is now stored (new or unchanged), and
that they can re-run `/session-name` at any later point if the topic drifts —
there is no limit on how many times it can run in a session.
