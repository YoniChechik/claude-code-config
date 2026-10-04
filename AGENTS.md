# CORE GUIDELINES

- The current year is 2026 (October at the time of writing).
- Commit and push after each meaningful change.
- NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.
- NEVER use `EnterPlanMode`/`ExitPlanMode` tools. ALWAYS use the USER `/plan` skill when planning is needed.
- **Never run `git worktree add` / `git worktree remove` directly**, and **never use Claude Code's built-in `EnterWorktree`/`ExitWorktree` tools**. use the worktree skill instead.
- NEVER create Artifacts or invoke the `artifact-design` skill unless the user EXPLICITLY asks for an artifact.
- NEVER use `sleep` to wait for a condition. Launch the work as a background shell command (`run_in_background: true`) and let the harness's own completion notification report it back.
- no comments in code! Never! See old comments? delete them.
- Python 3.14+ allows paren-free exception tuples in `except` clauses without an `as` binding (PEP 758) — e.g. `except jwt.PyJWTError, KeyError:` is VALID; parens are only required when binding via `as` — so NEVER "fix" a paren-less `except A, B:`, and verify Python syntax with the project interpreter (`uv run ...`), not a bare pre-3.14 system `python3`/`ast.parse` which FALSELY flags it as a SyntaxError.
- Never use legacy or deprecated libraries/ dependencies.
- always prefer existing libraries over writing new code. Only write new code if the library does not exist or is not maintained.
- NEVER use `ScheduleWakeup`/the `/loop` skill to poll for status — not for a subagent/backgrounded Bash command the harness already auto-notifies on, and not for external state either (a live deploy, a CI run). If something needs polling, push the sleep-and-recheck loop INSIDE a single backgrounded shell command and wait for that one process's own completion notification (or `Monitor` it) — never repeatedly re-invoke yourself via wakeup ticks to check status.
- ALWAYS run the `/session-name` skill at the very start of a session (as soon as the task is known), and run it again every time the session's scope/task changes — the label must always match what the session is currently doing right now, not what it started as.


# Work Continuation

By default **you should not stop a session at all**. the only reason to stop a session is if you are fully done and ALL OPEN ENDS ARE CLOSED.

found an open end? list it and fix it! the only open ends that you do not auto-fix are such that are extremely big major architectural decisions that are a paradigm shift than what we currently work. by default if you think to stop- 99% chance will be the user just green-light you, so don't even ask. 

If you contemplate between 2 appproaches- take the cleaner (even if longer) route- the one that will hold for longer.

Fix errors immediately when you find them — there is NO "pre-existing, so I'll leave it" exception.


# GCLOUD AUTH

Org session-control policy expires gcloud credentials daily (24h max, no way around it). One command refreshes both the regular login and Application Default Credentials (ADC, needed by Pulumi/GCS):

```
gcloud auth login <email> --update-adc
```

Run this directly when a `gcloud`/`pulumi` command fails with an auth error.

# RTK

@RTK.md
