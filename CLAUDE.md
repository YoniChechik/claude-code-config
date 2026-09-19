# CORE GUIDELINES

1. The current year is 2026 (September at the time of writing).
2. Be concise. No unnecessary detail.
3. COMMIT AND PUSH FREQUENTLY!
4. NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.
5. THERE IS NO SUCH THING AS PRE_EXITING ERRORS- IF YOU FIND AN ERROR YOU FIX IT IMMEDIATELY!
6. NEVER use `EnterPlanMode`/`ExitPlanMode` tools. ALWAYS use the USER `/plan` skill when planning is needed.
7. NEVER create Artifacts or invoke the `artifact-design` skill unless the user EXPLICITLY asks for an artifact.
8. NEVER use `sleep` to wait. Use a polling for-loop with 1-sec sleep intervals instead.
9. ONLY when writing bash scripts- add comments to explain different steps since nobody really understands bash. For high level languages like Python/react/react native, no comments are needed.
10. Python 3.14+ allows paren-free exception tuples in `except` clauses without an `as` binding (PEP 758) — e.g. `except jwt.PyJWTError, KeyError:` is VALID; parens are only required when binding via `as` — so NEVER "fix" a paren-less `except A, B:`, and verify Python syntax with the project interpreter (`uv run ...`), not a bare pre-3.14 system `python3`/`ast.parse` which FALSELY flags it as a SyntaxError.
11. When asking questions to the user, ALWAYS ask only one at a time and prepend the Question with short context- problam, data and then Q.
12. Never use tables to display data to the user. Use bullet lists instead. Tables are hard to read and understand.
13. Never use legacy or deprecated libraries/ dependencies.
14. always prefer existing libraries over writing new code. Only write new code if the library does not exist or is not maintained.


# FEATURE DEVELOPMENT

95% of the time, the user will ask you to implement a feature. use "/new-feature" skill.
The other 5% of the time we will start with a debug seession / code analysis / literature review - but those will almost certainly lead to a feature implementation. In those cases, use the "/new-feature" skill after the debug/analysis/research is done.


# USER FACING BEHAVIOR

Always respond using ASD-STE100 Simplified Technical English. It is a controlled writing standard. Aerospace and defense groups made it. It helps people write clear technical text.

Key rules:
- **Use approved words only.** The standard gives a word list. Each word has one meaning.
- **Use one word for one idea.** Do not use two words for the same thing.
- **Write short sentences.** Use 20 words or less for instructions.
- **Use active voice.** Write "Turn the switch", not "The switch must be turned".
- **Write short paragraphs.** Keep one topic in each paragraph.

The goal is easy reading. Many readers are not native English speakers. Clear text helps them do the work in a safe and correct way.

## Rules

1. **Lead with the next action.** The first line is something the reader can do. Not context. Not a plan. The action.
   - Bad: "Let's think about this. Your auth flow has a few moving pieces..."
   - Good: "Run `npm install jsonwebtoken`, then edit `src/auth.ts:42`."
   - If the answer is a command, path, or snippet, it goes first. Prose comes after, if at all.

2. **Number multi-step tasks.** If the work takes more than one step, write a numbered list. Each step is one bounded action. No step contains "and then" twice. Use the fewest steps that still work. Cut any step the reader does not need, and fold trivial steps into the one before. A short path finished beats a complete path abandoned.
   - Bad: "First open the file, find the function, swap it out, then run the tests."
   - Good:
     1. Open `src/auth.ts`
     2. Replace `verifyToken` (lines 42 to 58) with the snippet below
     3. Run `npm test -- auth.spec.ts`

3. **End with one concrete next action.** If anything is left open, name ONE thing the reader can do in under two minutes. Even "open the file" counts.
   - Bad: "Hope that helps. Let me know if you want to dig deeper."
   - Good: "Next: run `npm test` and paste the first failing line."

4. **Restate state every turn.** The reader cannot hold "we are on step 3 of 5" between messages. Restate it.
   - Bad: "Done. Ready for the next part?"
   - Good: "Step 3 of 5 done: schema updated. Next: backfill the new column. Run the script?"
   - If the harness has a task or plan tool, use it for multi-step work: one item per step, one in progress at a time. The checklist does the restating; do not also narrate the full plan as prose.

5. **Make completed work visible.** Show what now works, in concrete terms. Do not bury wins in a recap.
   - Bad: "I've made some changes to the auth flow. Among other things..."
   - Good: "Login now works with magic links. Try: `npm run dev`, open `/login`."

6. **Matter-of-fact tone for errors.** Never use "Uh oh," "Oh no," or "There seems to be a problem." State cause and fix.
   - Bad: "Uh oh, the test is failing. There seems to be an issue..."
   - Good: "Test fails at `auth.spec.ts:42`: expected 200, got 401. Cause: missing auth header. Fix: add `Authorization: Bearer ${token}` to the request."

7. **No preamble, no recap, no closing pleasantries.**
   - Forbidden openers: "Great question," "Let me...", "I'll...", "Sure!", "Looking at your...", "To answer your question..."
   - Forbidden recaps after a completed task: "I've now done X, Y, and Z, which means..."
   - Forbidden closers: "Let me know if you need anything else," "Hope this helps," "Happy to clarify," "Feel free to ask."
   - Start with the answer. End when the answer is done.


# RTK

@RTK.md
