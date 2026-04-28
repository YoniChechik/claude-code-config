# Multi-Session Architecture

How `~/.claude/` handles multiple Claude Code sessions running simultaneously
across multiple terminal windows and multiple git clones.

This is an internal design doc. It describes what actually happens, including
gaps and known weaknesses, not how things "should" work.

---

## TL;DR

- **Session identity** is owned entirely by Claude Code itself. The harness
  generates a `sessionId` (UUID) and a per-process file at
  `~/.claude/sessions/<pid>.json`. No hook script in this repo creates or
  reads that ID for routing.
- **Per-session routing** for webhooks is done by the MCP `webhook` server
  (`channel/webhook.ts`), which mints a random `sessionToken` at startup and
  exposes it together with the OS-assigned HTTP port via the `get_port`
  MCP tool. External scripts (the CI watcher) hold onto `(port, token)` for
  the lifetime of the session.
- **Per-clone routing** is done entirely via **branch name** as a namespace.
  `/tmp/ci_watch_state_<branch>`, `/tmp/ci_watch_lock_<branch>`,
  `/tmp/ci_watch_pr_<branch>`, and `/tmp/ci_watch_<branch>.log` all key on
  branch.
- **There is no real session-id-to-file mapping in any hook script.** The
  scripts in `~/.claude/scripts/` derive everything they need at hook-call
  time from `cwd` (passed in the hook payload) and from `git rev-parse`.

---

## 1. Session identity

### Where the session ID comes from

Claude Code itself generates `sessionId` as a UUID and writes a per-process
record:

```
~/.claude/sessions/<PID>.json
```

Example contents:

```json
{
  "pid": 41206,
  "sessionId": "f100b1d8-0db8-4a61-93ee-c1ca92fad161",
  "cwd": "/Users/yonichechik/.claude",
  "startedAt": 1777358909906,
  "version": "2.1.121",
  "kind": "interactive",
  "status": "busy",
  "bridgeSessionId": "session_0177r4i8vGWZEUkb3ox7NtSq"
}
```

There is also `~/.claude/session-env/<sessionId>/` (mostly empty in
practice) that Claude Code uses for per-session env scratch space.

### How hook scripts see the session ID

Every hook receives a JSON payload on stdin that includes `session_id`,
`cwd`, `tool_name`, and `tool_input`. Only one script in
`~/.claude/scripts/` even references the field by name
(`pre_tool_use__base_dir_protect.sh`, in a comment), and **none** of them
use it for routing.

In other words: from the perspective of the user-authored hooks in this
repo, sessions are anonymous. They are differentiated by `cwd` and by the
git branch in that cwd.

---

## 2. Multi-window handling

Two simultaneous Claude Code windows produce two distinct
`~/.claude/sessions/<pid>.json` files (different PIDs, different
`sessionId`s). Each window has its own MCP webhook server (because the
`webhook.ts` process is spawned per session by the MCP runtime), so each
session has its own:

- random `sessionToken` (UUIDv4 from `randomUUID()`)
- HTTP port (OS-assigned via `listen(0, '127.0.0.1')`)

```
                    ┌─────────────────────────┐
   Window A   ────► │ Claude Code session A   │ ──► spawns webhook MCP A
   (PID 41206)      │ sessionId: f100b1d8…    │     port 51234, token aaa…
                    └─────────────────────────┘

                    ┌─────────────────────────┐
   Window B   ────► │ Claude Code session B   │ ──► spawns webhook MCP B
   (PID 92307)      │ sessionId: f92149f8…    │     port 58912, token bbb…
                    └─────────────────────────┘
```

Beyond that, **the system does not actively "track which window is which."**
Hook scripts that print escape sequences (titles, badges, tab colors) write
to `/dev/tty`, which is the tty of the terminal that spawned the Claude
process — so each window's escape sequences naturally land in its own tab.

`notify_waiting.sh` calls `git rev-parse --abbrev-ref HEAD` to set the iTerm
title to `🔴 <branch> waiting... 🔔`. The branch is the user-visible label
that tells you which window is which.

---

## 3. Multi-clone handling

The clone-per-feature workflow is the load-bearing primitive. Each feature
lives in:

```
<repo>/_clones/<feature-name>/
```

with the branch name equal to `<feature-name>`. `create-clone` enforces this:
it creates `_clones/<FEATURE_NAME>` and either checks out an existing
branch with that name or creates+pushes a new one. `status_line.sh` warns
loudly if `clone_dir != branch`.

Because branch == clone-dir-name == feature-name, **branch name is a stable
unique key for everything CI-related**, and that is what the watcher and
status line use.

```
~/repo/                             ← base clone, branch: main
~/repo/_clones/feat-foo/            ← branch: feat-foo
~/repo/_clones/fix-bar/             ← branch: fix-bar
~/repo/_clones/refactor-baz/        ← branch: refactor-baz
```

A Claude session associates with its clone via `cwd`. Hooks read
`cwd` from the hook payload (or call `git rev-parse` from the cwd they
were invoked in) to derive the branch. There is no explicit session→clone
table.

`pre_tool_use__base_dir_protect.sh` follows `cd` and `pushd` segments
within a single Bash command so that `cd /outside && git commit` is denied
even if the session's cwd is inside `_clones/`. It also resolves
`git -C <path>` flags. It does not, however, persist any state between
calls — each call recomputes from scratch.

---

## 4. State file naming

All shared state lives in `/tmp` and is namespaced by **branch name**, not
by session ID:

| File                           | Writer                   | Reader                   |
|--------------------------------|--------------------------|--------------------------|
| `/tmp/ci_watch_state_<branch>` | `ci_watch_persistent.sh` | `status_line.sh`         |
| `/tmp/ci_watch_lock_<branch>`  | `ci_watch_persistent.sh` | `ci_watch_persistent.sh` |
| `/tmp/ci_watch_pr_<branch>`    | `ci_watch_persistent.sh` | `status_line.sh`         |
| `/tmp/ci_watch_<branch>.log`   | `ci_watch_persistent.sh` | (humans, `tail -f`)      |

State values written to `ci_watch_state_<branch>` are: `running`, `passed`,
`failed`, `conflict`, `behind`, `merging`. `status_line.sh` color-codes
them. `ci_watch_pr_<branch>` is a JSON cache of `gh pr view` (url, number,
state, mergeable, mergeStateStatus, mergeCommit) so the status line never
calls `gh` itself.

### Why branch and not session ID

A clone's branch is a 1:1 stable key for "this feature". The watcher needs
to outlive any single Claude session — you can close the window, reopen
it, and the watcher (still running with the original session's port) keeps
posting to the now-dead webhook until its health check fails.
Branch-keyed state files give the new window's `status_line.sh` something
to display the moment it opens, even before the user runs `/ci` again.

### Collision behavior

Multiple windows opened against the *same* `_clones/<branch>` directory
will share the same state files. The lock file
(`/tmp/ci_watch_lock_<branch>`) is the only mechanism that prevents two
concurrent watchers from racing — see §7.

---

## 5. Sound / notification routing

### `stop__sound.sh` (Stop hook)

This script is invoked by the harness in the context of the stopping
session — there's no cross-session routing problem. It does:

1. Read the hook JSON payload from stdin, extract `transcript_path`.
2. Parse the transcript JSONL to count **active background subagents**:
   collect all `agentId`s that returned `async_launched`, subtract the
   ones whose `<task-id>` later appeared inside a
   `<status>completed</status>` block. If `active > 0`, suppress the
   sound and exit silently — the user will get a sound when the actual
   subagent reports back.
3. Otherwise: turn the iTerm tab green via OSC-6, clear the iTerm badge
   via OSC-1337, and call `notify_waiting()` which plays
   `Glass.aiff` and sets the tab title to `🔴 <branch> waiting... 🔔`.

The "which session stopped" question is answered by the harness: the hook
runs as a child of the right session and writes to `/dev/tty`, so the
right tab gets the right sound and color.

The transcript-scanning logic is the most session-aware piece in the
whole repo and it's only used to suppress duplicate sounds within a
single session.

### `notification__sound.sh`

Reads `notification_type` from the payload. For `idle_prompt`,
`task_completed`, and anything containing `background`, exits silently.
Otherwise plays Glass.aiff and updates the tab title.

### `stop_failure__rate_limit.sh`

Sets the iTerm tab badge to `⏳ RATE LIMITED (<OrgName>)` (org name pulled
from `~/.claude.json`) and tab color to orange. Logs the full payload to
`~/.claude/logs/rate_limit.log`. Again: the hook runs in the right
session's tty, so routing is automatic.

---

## 6. CI watcher

### How it associates with a session

Two arguments and one piece of mutable state tie a watcher to its session:

1. `PORT` — the HTTP port of the spawning session's `webhook.ts` MCP
   server.
2. `SESSION_TOKEN` — random UUID minted by `webhook.ts` at startup.
3. The `BRANCH` argument names the file namespace.

The `/ci` skill does:

```bash
# 1. Get port + token from the MCP webhook tool (returns "PORT:TOKEN")
# 2. Determine branch via `git branch --show-current`
# 3. Detach with shell-level backgrounding so the watcher outlives the subagent
bash ~/.claude/scripts/ci_watch_persistent.sh "$PORT" "$BRANCH" "$SESSION_TOKEN" \
  </dev/null >>/tmp/ci_watch_${BRANCH}.log 2>&1 &
```

### How the watcher detects its session has died

Every loop iteration:

```
GET http://127.0.0.1:$PORT/health  →  expects "ok:$SESSION_TOKEN"
```

If the port is dead, or the response token doesn't match (e.g. a *different*
session bound the same port after the old one exited), the watcher exits.

The 5-attempt-with-2s-sleep retry loop is specifically for macOS sleep/wake:
a localhost server can be unreachable for a few seconds when the Mac wakes,
and we don't want the watcher to commit suicide over that.

### Why both `PORT` and `SESSION_TOKEN`?

`PORT` alone is unsafe. A new Claude session opened after the old one
exited can be assigned the same OS port. The token check ensures we're
talking to the *same* webhook server that asked for the watcher.

### Lifetime

```
session opens ──► /ci skill ──► watcher started (port, token, branch)
                                          │
                                          ▼
                              loops every 5s, posts to webhook
                                          │
       session closes ─────────────────►  health check fails
                                          │
                                          ▼
                                       watcher exits cleanly
                                       (cleans up lock, but per
                                        trap also cleans state
                                        files unless KEEP_STATE_FILE)
```

### Cross-session takeover

If the user runs `/ci` twice for the same branch (e.g. from a re-opened
window), the second invocation reads `/tmp/ci_watch_lock_<branch>`, sees
the old PID, and `kill`s it before claiming the lock with its own PID.
The new watcher has the new session's `(PORT, SESSION_TOKEN)`. This is
how a re-opened window "reattaches" to a feature's CI watcher. Nothing
about the old session's identity is preserved — the new watcher is a
fresh process, just keyed on the same branch.

---

## 7. Lock files and concurrency

### CI watcher lock

```
/tmp/ci_watch_lock_<branch>   ← contains PID
```

- Created on watcher startup with `echo $$ > "$LOCK_FILE"`.
- On startup, if the file exists and the PID is still alive, the new
  watcher sends `SIGTERM` to the old one, waits 1 second, then claims
  the lock.
- Cleaned by the EXIT trap in the watcher.

This is **branch-scoped, not session-scoped**, by design — the goal is
"only one watcher per branch", not "one watcher per session".

### State files

Cleaned by the same EXIT trap unless `KEEP_STATE_FILE=1` is set right
before an intentional exit (used after main-CI resolves so the status
line still shows the final result).

### Other concurrency concerns

There is no global `~/.claude` lock. Hook scripts assume independent
operation:

- `quality_check.sh`, `post_tool_use__*.sh` operate on the file path
  passed in the hook payload — naturally per-call.
- `pre_tool_use__base_dir_protect.sh` is purely a function of its input.
- `session_start.sh` does `git fetch -p` and a fast-forward merge in the
  cwd. Two windows starting simultaneously in the *same* base repo would
  race here, but git's own ref-locking handles it gracefully — worst
  case one of them sees "Already up to date".
- `startup__rtk_update.sh` runs `brew upgrade rtk` and `rtk init -g`. Two
  simultaneous startups could double-run brew; harmless but wasteful.

---

## 8. End-to-end flow: two windows, two clones

```
┌────────────────────────────────────────────────────────────────────┐
│ Window A (cwd = ~/repo/_clones/feat-foo, branch = feat-foo)        │
│                                                                    │
│ Claude session A                                                   │
│   ├── sessions/<pidA>.json   sessionId: aaa…                       │
│   ├── webhook MCP A          port 51234, token aaa-tok             │
│   ├── status_line.sh reads /tmp/ci_watch_state_feat-foo            │
│   │                          /tmp/ci_watch_pr_feat-foo             │
│   └── /ci  ──►  ci_watch_persistent.sh 51234 feat-foo aaa-tok      │
│                   ├── /tmp/ci_watch_lock_feat-foo  (PID = watcher) │
│                   ├── /tmp/ci_watch_state_feat-foo                 │
│                   ├── /tmp/ci_watch_pr_feat-foo                    │
│                   └── posts to http://127.0.0.1:51234              │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Window B (cwd = ~/repo/_clones/fix-bar, branch = fix-bar)          │
│                                                                    │
│ Claude session B                                                   │
│   ├── sessions/<pidB>.json   sessionId: bbb…                       │
│   ├── webhook MCP B          port 58912, token bbb-tok             │
│   ├── status_line.sh reads /tmp/ci_watch_state_fix-bar             │
│   │                          /tmp/ci_watch_pr_fix-bar              │
│   └── /ci  ──►  ci_watch_persistent.sh 58912 fix-bar bbb-tok       │
│                   ├── /tmp/ci_watch_lock_fix-bar                   │
│                   ├── /tmp/ci_watch_state_fix-bar                  │
│                   └── posts to http://127.0.0.1:58912              │
└────────────────────────────────────────────────────────────────────┘
```

Disjoint state — no contention, because the branch names differ.

---

## 9. Known gaps and weaknesses

- **No session-id-keyed state.** Everything is keyed on branch. If you
  ever open two windows pointing at the *same* clone (same branch),
  the second `/ci` will SIGTERM the first session's watcher, and both
  status lines will read the same `ci_watch_state_<branch>` file. There's
  no way to have "session A's CI view" and "session B's CI view" diverge.

- **`status_line.sh` reads `/tmp/ci_watch_pr_<branch>` even after the
  watcher dies.** The trap normally deletes it, but if the watcher is
  killed with `SIGKILL` (e.g. machine power-off) the cache file is
  stale until the next watcher run cleans it.

- **Webhook port is OS-assigned and not advertised anywhere on disk.**
  The only way for an external script to reach a session's webhook is to
  call the `get_port` MCP tool *from within that session*. Cross-session
  scripting is not supported by design.

- **`session_start.sh` runs `git merge --ff-only` against the current
  branch's upstream on every session start.** For a clone that's actively
  being worked on, this can silently fast-forward the working tree under
  another window's feet if two sessions share the same clone (which the
  workflow tries to prevent, but doesn't enforce).

- **`startup__rtk_update.sh` is not gated by a lock.** Two simultaneous
  starts double-execute `brew upgrade` and `rtk init -g`. Not harmful,
  just wasteful.

- **Subagent-active detection in `stop__sound.sh` is per-transcript.** It
  relies on the assumption that the transcript file is exclusive to one
  session, which it is — but the parser is a regex-and-JSONL walk, not
  a structured query, so transcript-format changes can silently break it.

- **`notify_waiting.sh` calls `git rev-parse` from whatever cwd the hook
  was invoked in.** If the hook somehow runs from outside a git repo, the
  title falls back to `no-repo`.

- **There is no central registry** that lists "all live Claude sessions
  and their webhook ports". `~/.claude/sessions/<pid>.json` is the closest
  thing, but it does not record the webhook port. If you wanted to broadcast
  to all sessions, you'd have to scan `lsof` for processes listening on
  127.0.0.1 and try `/health` on each.

- **No cleanup of `/tmp/ci_watch_*` for branches that were merged & deleted
  long ago.** The watcher's own EXIT trap handles its own files, but a
  watcher killed by `SIGKILL` leaves orphans that nothing collects.

---

## 10. Quick reference

| Question                                           | Answer                                                                     |
|----------------------------------------------------|----------------------------------------------------------------------------|
| Where does the session ID come from?               | Claude Code generates a UUID; written to `~/.claude/sessions/<pid>.json`   |
| Do hook scripts use it?                            | Effectively no — only `cwd` and branch matter                              |
| How is multi-window disambiguated?                 | tty isolation + per-session MCP webhook (port + random token)              |
| How is multi-clone disambiguated?                  | branch name == clone dir name; used as `/tmp` namespace                    |
| How does the CI watcher reach its session?         | `(PORT, SESSION_TOKEN)` passed at launch; verified each loop via `/health` |
| What guards against two watchers per branch?       | `/tmp/ci_watch_lock_<branch>`; new wins, kills old                         |
| How does the status line know CI state?            | reads `/tmp/ci_watch_state_<branch>` and `/tmp/ci_watch_pr_<branch>`       |
| How does `stop__sound.sh` know which tab to color? | It runs in the right session's tty — writes go to `/dev/tty`               |
