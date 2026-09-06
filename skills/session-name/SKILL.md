---
name: "session-name"
description: "Assign or update a short label describing what this Claude Code session is currently doing, stored in a per-session sidecar file so status_line.sh and the tab title can show it"
argument-hint: "[optional forced name]"
---

Sets (or re-sets) the current session's display name: a short, human-readable
label stored in a per-session sidecar file. `status_line.sh` and the tab-title
mechanism read only this file — there is no fallback to the branch/worktree
name or to Claude Code's own native `session_name` field. Safe to re-run any
number of times in one session as the topic drifts; each run is a fresh
decision, not a one-time setup step.

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
silently clear the status-line segment and blank the tab title instead of
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

- Make **no write**. Do not touch the sidecar file, do not re-emit the title
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

## Step 8: Re-emit the tab title immediately

This call site is a live skill invocation, not a hook — it has no JSON-output
channel, so it must write the OSC 0 escape straight to the tty, the same way
`create_worktree.sh` does, rather than waiting for the next Stop/waiting event
to pick up the change.

`_notify.sh` is already sourced from Step 2. `%s` is load-bearing: it prints
`$NAME` as inert text, so nothing inside the name can be re-read as an escape.

```bash
target_tty=$(_resolve_target_tty)
printf '\033]0;%s\007' "$NAME" > "$target_tty" 2>/dev/null || true
```

## Step 9: Report

Tell the user the session name that is now stored (new or unchanged), and
that they can re-run `/session-name` at any later point if the topic drifts —
there is no limit on how many times it can run in a session.
