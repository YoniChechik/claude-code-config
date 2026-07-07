# CORE GUIDELINES

- The current year is 2026.

- Be concise. No unnecessary detail.
- ALWAYS USE TASKS! EVEN FOR SIMPLE 1 BLOCK TASKS! AFTER READING SKILL ADD ALL NEW TASKS TO TASK LIST IMMEDIATELY! REMOVE each completed task from the list — only uncompleted tasks should remain visible.
- COMMIT AND PUSH FREQUENTLY!
- NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.
- THERE IS NO SUCH THING AS PRE_EXITING ERRORS- IF YOU FIND AN ERROR YOU FIX IT IMMEDIATELY!
- NEVER use `EnterPlanMode`/`ExitPlanMode` tools. ALWAYS use the USER `/plan` skill when planning is needed.
- NEVER create Artifacts or invoke the `artifact-design` skill unless the user EXPLICITLY asks for an artifact. Do not proactively produce artifacts.
- When working on feature- make sure you used `/create-clone` or `/cd-permanent` to work inside the clone. NEVER work directly in the base repo directory.
- NEVER use `sleep` to wait. Use a polling for-loop with 1-sec sleep intervals instead. Each loop must complete in max 10 sec (target avg 3 sec); if the condition isn't met by then, let the loop iterate again — never extend a single loop's timeout.
- ONLY when writing bash scripts- add comments to explain different steps since nobody really understands bash. For high level languages like Python/react/react native, no comments are needed unless the logic is truly complex and non-obvious.
- For gcloud re-auth (token expired): FIRST invoke the `/notify-waiting` skill (or run `bash -c 'source /Users/yonichechik/.claude/scripts/_notify.sh && notify_user_attention'`) to ping the user, since the next step blocks waiting for browser approval. Then just run `gcloud auth login` directly via a subagent Bash call (NOT `--no-launch-browser`, NOT named pipes, NOT capturing URLs). It opens Chrome automatically, user approves, done — valid for ~1 day. Never attempt manual PKCE/OAuth flows.
- When launching long-running background processes from subagents, NEVER use `run_in_background=true` on the Bash tool — the process gets killed when the subagent exits. Instead, use shell-level backgrounding: `<command> </dev/null >/dev/null 2>&1 &` (or redirect to a log file instead of `/dev/null`).
- Python 3.14+ (this repo) allows paren-free exception tuples in `except` clauses without an `as` binding (PEP 758) — e.g. `except jwt.PyJWTError, KeyError:` is VALID; parens are only required when binding via `as` — so NEVER "fix" a paren-less `except A, B:`, and verify Python syntax with the project interpreter (`uv run ...`), not a bare pre-3.14 system `python3`/`ast.parse` which FALSELY flags it as a SyntaxError.

@RTK.md
