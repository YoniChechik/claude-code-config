---
name: "session-name"
description: "Assign or update a short label describing what this session is currently doing, stored in a per-session sidecar file so a status line and the workspace title can show it; where this tool has a native rename command (e.g. Claude Code's /rename inside cmux), also triggers that so the terminal title, session picker, and any companion app pick it up too"
argument-hint: "[optional forced name]"
---

Sets (or re-sets) the current session's display name: a short, human-readable
label stored in a per-session sidecar file. A status line and the cmux
workspace title read only this file — there is no fallback to the
branch/worktree name. Where this tool also has its own native session-rename
command (Steps 5 and 7), this skill additionally triggers it inside cmux or
plain iTerm2 — a separate naming layer covering the session picker and any
companion app. Inside iTerm2 (Step 6), it also sets the raw OS-level tab
title directly. Safe to re-run any number of times in one session as the
topic drifts; each run is a fresh decision, not a one-time setup step.

## Step 1: Resolve the candidate name

Run `resolve` from this skill's own directory (the "Base directory for this
skill" path given above, not a hardcoded path) against `$ARGUMENTS` if
non-empty, or otherwise a short (well under 35 codepoints) label you decide
from the current conversation, branch name, and task at hand:

```bash
bash "<skill-base-dir>/rename_session.sh" resolve "<candidate name>"
```

This sanitizes and caps the candidate (strips control bytes and backslashes,
drops invalid UTF-8, trims whitespace, caps at 35 Unicode **codepoints** —
never a byte-slice, which can split a multi-byte character mid-sequence) and
compares it to the currently stored name.

- **Exit 1** (a candidate that sanitizes to empty — all-whitespace, all-control-byte,
  or all-backslash): report the error to the user and stop. Writing an empty
  name would silently clear the status-line segment and blank the workspace
  title instead of naming the session.
- **Exit 10** (no-op — the sanitized candidate already matches the stored
  name): tell the user the current session name still fits, and stop here.
  This is a first-class, correct outcome — renaming is not mandatory just
  because this skill ran. Do not proceed to Step 2.
- **Exit 0**: the printed name differs from what's stored. Proceed to Step 2.

## Step 2: Mandatory orchestrator confirmation (subagents only)

Decide whether *you*, the agent currently executing this skill, are the
top-level orchestrator (the agent talking directly to the user in this
session) or a subagent — including a sub-subagent nested at any depth,
launched via the `Agent` tool.

- **You are a subagent (any depth):** you must NOT write the sidecar file
  unilaterally. Load `SendMessage` if not already available
  (`ToolSearch` query `select:SendMessage`), then call
  `SendMessage(to: "main", message: "<resolved name> — <brief reason>")` and
  wait for `main`'s reply. Treat the reply as either a confirmation (proceed
  with the resolved name) or an adjusted name (re-run Step 1's `resolve` on
  it instead). Only after this reply do you proceed to Step 3. The one
  caveat: `SendMessage` cannot bypass a permission prompt blocking you — the
  user's approve/deny is still required first if one is in the way.
- **You are the top-level orchestrator:** no ping needed. Proceed directly to
  Step 3, the same way `create-worktree` decides a feature name from a
  description without asking anyone else first.

## Step 3: Write the sidecar file atomically

```bash
bash "<skill-base-dir>/rename_session.sh" write "<final resolved name>"
```

This never does a direct truncate-then-write — a status line may poll this
file on a short interval and must never observe a half-written or empty file
mid-update. The temp file is removed on any failure; reporting a new name to
the user after a write that did not land is worse than reporting the failure.

## Step 4: Rename the cmux workspace

Terminal OSC 0/2 title escapes have no effect on cmux's sidebar (verified
empirically — cmux does not read them), so the workspace title is set through
cmux's own CLI instead: `cmux rename-workspace`. It defaults to the current
workspace via `$CMUX_WORKSPACE_ID` (auto-set in every cmux terminal), so no
explicit `--workspace` flag is needed here.

When `CMUX_WORKSPACE_ID` is unset (not running inside cmux — e.g. a plain
terminal or an unrelated wrapper), skip the rename silently rather than
erroring: the sidecar file written in Step 3 is still the source of truth for
the status line, so the session name is not lost, only the cmux sidebar
label.

```bash
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    cmux rename-workspace -- "$NAME" 2>/dev/null || true
fi
```

Note: cmux's opt-in `automation.workspaceAutoNaming` setting (off by default)
drives its OWN turn-end AI naming of workspaces for supported agents. That is
a separate, automatic mechanism gated on a live socket setting — this skill's
explicit rename is independent of it and runs regardless of whether that
setting is ever turned on.

## Step 5: Trigger this tool's native rename (cmux only)

The sidecar file (Step 3) and cmux workspace title (Step 4) are a
project-local naming layer — they do not touch this TOOL's own native session
name (for Claude Code: `~/.claude/sessions/<pid>.json`'s `name` field), which
drives the terminal title, the session/`/resume` picker, and any companion
app. That native field typically has no exposed tool or file-edit path:
editing a session JSON file directly, or appending a fabricated record to a
transcript, does NOT propagate to a companion app — only the tool's own real
native-rename command does, because it also pushes the change live over the
session's existing connection.

The command name is tool-specific: Claude Code's is `/rename`; another tool
may use something else (e.g. `/name`). Set `NATIVE_RENAME_CMD` before running
this skill if the default is wrong for this environment:

```bash
NATIVE_RENAME_CMD="${NATIVE_RENAME_CMD:-/rename}"
```

When running inside cmux (`$CMUX_SURFACE_ID` is set), `cmux send` delivers
text to this session's own terminal surface exactly as if it were typed —
cmux is the pty's actual owner, so this is not a hack, it is the documented
path (`cmux send --help`). Use it to fire the real native rename:

```bash
if [[ -n "${CMUX_SURFACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    cmux send -- "${NATIVE_RENAME_CMD} ${NAME}\n"
fi
```

Confirmed empirically for Claude Code (2026-09-18): this updates
`sessions/<pid>.json`'s `name` / `nameSource:"user"` / `formerNames`, the
`/resume` picker's title, and the Remote Control app's displayed name — all
three at once, even mid-turn while the orchestrator is still busy. Skip
silently when `CMUX_SURFACE_ID` is unset (not running inside cmux) — there is
no other known path to the native field from inside a session.

Do not attempt this via raw tty `TIOCSTI` injection: macOS restricts
`TIOCSTI` to the tty's session leader (the owning process itself) or root —
a sibling process gets `EPERM` even with read/write permission on the device
file, confirmed empirically.

## Step 6: Set the raw iTerm2 tab title

This is a fourth, independent naming surface — the actual OS-level terminal
tab title — distinct from the sidecar file (Step 3, drives the status line),
the cmux workspace label (Step 4), and this tool's native session name
(Step 5, drives its own `/resume` picker and companion app). Only applies
inside iTerm2; skip silently everywhere else, since the OSC 1 tab-title
escape means different things (or nothing at all) in other terminals and
multiplexers.

`title`/`title-reset` are zsh functions defined in `~/.claude/setup.sh` for
interactive use (`title "name"` pins the tab title; `title-reset` restores
oh-my-zsh's auto-titling) — but a `Bash` tool call runs in a **fresh,
separate subprocess** that never inherits interactive shell functions, and
sourcing `setup.sh` from the wrong shell risks running its unrelated
one-time installer body (see the file's own header comment). Do not call
`title` here.

A `Bash` tool call's own stdout is also not the session's real tty (confirmed
empirically 2026-09-28: `[ -t 1 ]` is false inside a `Bash` tool call) — it is
a pipe the harness captures to build the tool result, so a plain
`printf '\e]1;...'` here never reaches the actual terminal; it just shows up
as literal escape bytes in the tool output. The escape must instead be
written directly to the session's real pty device, discovered via the same
`unique ID` lookup Step 7 uses (see that step for why the `w2t1p0:` prefix on
`$ITERM_SESSION_ID` must be stripped before comparing):

```bash
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && [[ -n "${ITERM_SESSION_ID:-}" ]]; then
    ITERM_SESSION_GUID="${ITERM_SESSION_ID#*:}"
    TTY_DEVICE=$(osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if unique ID of s is "$ITERM_SESSION_GUID" then
                    return tty of s
                end if
            end repeat
        end repeat
    end repeat
end tell
APPLESCRIPT
    )
    if [[ -n "$TTY_DEVICE" ]]; then
        printf '\e]1;%s\a' "$NAME" > "$TTY_DEVICE"
    fi
fi
```

Note: this sets the title for only the current prompt cycle, not a
persistent override — the `TITLE_OVERRIDE` sticky flag lives in the
interactive shell's own process memory and cannot be set from here, since
this command runs in a short-lived subprocess that exits immediately after.
If oh-my-zsh's auto-title hook fires again on the next prompt, it will
overwrite this. That's acceptable here: the sidecar file / status line
(Step 3) remains the durable source of truth for the session name.

## Step 7: Trigger this tool's native rename (plain iTerm2 only)

Step 5 already fires this tool's native rename inside cmux, via `cmux send`
injecting text into the session's own pty. Plain iTerm2 (no cmux) needs the
same trick through a different mechanism: iTerm2's own AppleScript
automation can `write text` into a specific session, which types into that
session's pty exactly as if the user had typed it themselves — the iTerm2
equivalent of `cmux send`, and the only known way to fire a real `/rename`
keystroke from inside the session it targets.

This only applies when cmux is not already handling it — `$CMUX_SURFACE_ID`
set means Step 5 already covered this session, so this step must not
double-fire the rename command into the same pty. It also only applies
inside plain iTerm2 (`$TERM_PROGRAM` is `iTerm.app`), and only when
`$ITERM_SESSION_ID` is set — every iTerm2 session exports this, but it is
prefixed with a window/tab/pane locator (e.g. `w2t1p0:44166DB0-...`) that
AppleScript's own `unique ID of session` does NOT include (that property
returns the bare GUID only) — strip everything up to and including the first
`:` before comparing, or the match never fires and `write text` silently
no-ops (confirmed empirically 2026-09-28: exit 0, no error, no keystroke
sent).

`$NAME` is already sanitized by `_sanitize_and_cap` (Step 1) and cannot
contain a backslash, but it can still contain a literal double quote, which
would otherwise break out of the AppleScript string literal — escape both
characters defensively before interpolating:

`write text`'s own `newline` parameter (default: appends a trailing return)
is NOT enough to actually submit the command — confirmed empirically
2026-09-28: injecting `write text "/rename Name"` (with or without a
separate follow-up `write text` of just a carriage return) leaves the text
sitting unsubmitted in Claude Code's input box every time, even though the
text itself appears correctly. Claude Code's own CLI evidently does not
treat a `write text`-delivered newline as "submit" the same way it treats a
genuine, individually-arriving keypress. The only mechanism confirmed to
actually submit it is a real OS-level key event via `System Events`, which
requires OS keyboard focus — so this step must explicitly select the target
session's window/tab and activate iTerm2 first. Only fire the key event once
iTerm2 has actually confirmed frontmost, so a focus change that lands
somewhere unexpected (another app, a dialog) never gets a stray Return typed
into it — worst case is the same as today's silent no-op, never worse:

```bash
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && [[ -n "${ITERM_SESSION_ID:-}" ]] && [[ -z "${CMUX_SURFACE_ID:-}" ]]; then
    NAME_ESCAPED="${NAME//\\/\\\\}"
    NAME_ESCAPED="${NAME_ESCAPED//\"/\\\"}"
    ITERM_SESSION_GUID="${ITERM_SESSION_ID#*:}"
    osascript <<APPLESCRIPT
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if unique ID of s is "$ITERM_SESSION_GUID" then
                    tell s to write text "$NATIVE_RENAME_CMD $NAME_ESCAPED" newline no
                    select w
                    select t
                    select s
                end if
            end repeat
        end repeat
    end repeat
    activate
end tell
delay 0.2
tell application "System Events"
    if (name of first process whose frontmost is true) is "iTerm2" then
        key code 36
    end if
end tell
APPLESCRIPT
fi
```

Skip silently (no error) whenever any of the three conditions is not met —
same pattern as Steps 4/5/6. Running this briefly steals OS focus to
iTerm2 (necessary for the real keypress — `write text` alone can target a
background session, but `System Events` cannot) and sends a real keystroke
into the current tab, so never fire it speculatively or as a dry run
against a live session.

## Step 8: Report

Tell the user the session name that is now stored (new or unchanged), and
that they can re-run `/session-name` at any later point if the topic drifts —
there is no limit on how many times it can run in a session.
