---
name: "session-name"
description: "Assign or update a short label describing what this session is currently doing, stored in a per-session sidecar file so a status line can show it; inside iTerm2, also sets the raw OS-level tab title and triggers this tool's native rename command so the terminal title, session picker, and any companion app pick it up too. Also records the session's exit predicate with --done."
argument-hint: "[optional forced name] [--done '<predicate item>']..."
---

1. Pick a short name (well under 35 characters) from `$ARGUMENTS` if given, otherwise from the current task and branch.
2. If you are a subagent (any depth), first `SendMessage(to: "main", ...)` with the name and reason, and use main's reply (confirmed or adjusted name). The top-level agent skips this.
3. Once the task is known, add the exit predicate: one `--done` per item. An item is `cmd:<command>` (a check that exits 0 when met), `merged:<owner/repo>#<pr>`, `staging:<owner/repo>`, `linear:<TEAM-123>:<state>` (met by a Linear `get_issue` read showing that state; one item per ticket), `surface:<owner/repo>:<simulator|local>` (accepts a verify run on that surface), or plain text. Work that merges needs at least one item that is not plain text. Items may be added during a prompt, never dropped.
4. Run the one script from this skill's base directory:

```bash
bash "<skill-base-dir>/rename_session.sh" "<name>" [--done '<item>']...
```

The script prints the new name when it changed. Unchanged: say nothing. Exit 1 means an error (report it). The predicate goes to the session ledger in `~/.claude/state/sessions/<session_id>/ledger.jsonl`. A repeat of the same predicate adds nothing. A changed predicate adds a new record, so say what changed and why. Re-run whenever the topic drifts. The iTerm2 part types `/rename <name>` + Enter into this session by its `$ITERM_SESSION_ID` (no focus change), so never run it as a dry run in a live session.
