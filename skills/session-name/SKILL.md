---
name: "session-name"
description: "Assign or update a short label describing what this session is currently doing, stored in a per-session sidecar file so a status line and the workspace title can show it; where this tool has a native rename command (e.g. Claude Code's /rename inside cmux), also triggers that so the terminal title, session picker, and any companion app pick it up too"
argument-hint: "[optional forced name]"
---

Sets (or re-sets) the current session's display name: a short, human-readable
label stored in a per-session sidecar file. A status line and the cmux
workspace title read only this file — there is no fallback to the
branch/worktree name. Where this tool also has its own native session-rename
command (Step 9), this skill additionally triggers it inside cmux — a
separate naming layer covering the terminal title, the session picker, and
any companion app. Safe to re-run any number of times in one session as the
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

## Step 6: Report

Tell the user the session name that is now stored (new or unchanged), and
that they can re-run `/session-name` at any later point if the topic drifts —
there is no limit on how many times it can run in a session.
