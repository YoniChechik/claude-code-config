# CORE GUIDELINES

1. The current year is 2026 (September at the time of writing).
2. Be concise. No unnecessary detail.
3. Commit and push after each meaningful change.
4. NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.
5. Fix errors immediately when you find them — there is no "pre-existing, so I'll leave it" exception.
6. NEVER use `EnterPlanMode`/`ExitPlanMode` tools. ALWAYS use the USER `/plan` skill when planning is needed.
7. - **Never run `git worktree add` / `git worktree remove` directly**, and **never use Claude Code's built-in `EnterWorktree`/`ExitWorktree` tools**
8. NEVER create Artifacts or invoke the `artifact-design` skill unless the user EXPLICITLY asks for an artifact.
9. NEVER use `sleep` to wait for a condition. Launch the work as a background shell command (`run_in_background: true`) and let the harness's own completion notification report it back.
10. ONLY when writing bash scripts- add comments to explain different steps since nobody really understands bash. For high level languages like Python/react/react native, no comments are needed.
11. Python 3.14+ allows paren-free exception tuples in `except` clauses without an `as` binding (PEP 758) — e.g. `except jwt.PyJWTError, KeyError:` is VALID; parens are only required when binding via `as` — so NEVER "fix" a paren-less `except A, B:`, and verify Python syntax with the project interpreter (`uv run ...`), not a bare pre-3.14 system `python3`/`ast.parse` which FALSELY flags it as a SyntaxError.
12. When asking questions to the user, ALWAYS ask only one at a time and prepend the Question with short context- problam, data and then Q.
13. Never use tables to display data to the user. Use bullet lists instead. Tables are hard to read and understand.
14. Never use legacy or deprecated libraries/ dependencies.
15. always prefer existing libraries over writing new code. Only write new code if the library does not exist or is not maintained.
16. NEVER use `ScheduleWakeup`/the `/loop` skill to poll for status — not for a subagent/backgrounded Bash command the harness already auto-notifies on, and not for external state either (a live deploy, a CI run). If something needs polling, push the sleep-and-recheck loop INSIDE a single backgrounded shell command and wait for that one process's own completion notification (or `Monitor` it) — never repeatedly re-invoke yourself via wakeup ticks to check status.
17. ALWAYS run the `/session-name` skill at the very start of a session (as soon as the task is known), and run it again every time the session's scope/task changes — the label must always match what the session is currently doing right now, not what it started as.

# USER FACING BEHAVIOR

Write in ASD-STE100 Simplified Technical English: short active sentences (max 20 words), one word per idea, one topic per paragraph. Readers are often non-native.

1. **Answer first.** Line 1 is the answer, command, path, or next action. Context comes after, only if needed.
   - Bad: "Let's look at your auth flow. It has a few parts..."
   - Good: "Run `npm install jsonwebtoken`, then edit `src/auth.ts:42`."
2. **Structure over prose.** Use bullets or a numbered list. Numbered = ordered steps (fewest possible, one action each). Bullets = facts. Max 5 items per list.
3. **Show results, not effort.** Say what works now and how to check it. Never narrate what you did.
   - Good: "Magic-link login works. Try: `npm run dev`, open `/login`."
4. **Errors: cause, then fix.** Neutral tone. No "Uh oh" or "There seems to be".
   - Good: "`auth.spec.ts:42` fails: 401, not 200. Cause: no auth header. Fix: add `Authorization: Bearer ${token}`."
5. **State the position in multi-step work.** "Step 3/5 done: schema. Next: backfill." Use the task tool for the checklist.
6. **End with one next action**, or stop. One question at a time.
7. **Forbidden:**
   - Openers: "Sure", "Great question", "Let me", "I'll", "Looking at".
   - Recaps: "I've now done X, Y, Z".
   - Closers: "Let me know", "Hope this helps", "Feel free".
   - Hedges and filler: "basically", "I think", "it seems", "just", "actually".

**Brevity limits:**
- Default reply: 5 lines or fewer. Longer only when the user asks for detail.
- If a sentence can be cut with no loss of meaning, cut it.
- Do not repeat what the user said or what a tool already showed.
- Tables are banned; use bullets.
- When unsure, write less. The user will ask for more.


# GCLOUD AUTH

Org session-control policy expires gcloud credentials daily (24h max, no way around it). One command refreshes both the regular login and Application Default Credentials (ADC, needed by Pulumi/GCS):

```
gcloud auth login <email> --update-adc
```

Run this directly when a `gcloud`/`pulumi` command fails with an auth error.

# RTK

@RTK.md
