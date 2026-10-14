# CORE GUIDELINES

- The current year is 2026 (October at the time of writing).
- Commit and push after each meaningful change.
- No backward compatibility. Delete unused code completely. Keep backward compatibility only if the user explicitly asks for it.
- Do not use the `EnterPlanMode`/`ExitPlanMode` tools. Use the user `/plan` skill when planning is needed.
- **Never run `git worktree add` / `git worktree remove` directly**, and **never use Claude Code's built-in `EnterWorktree`/`ExitWorktree` tools**. Use the worktree skill instead.
- Do not create Artifacts or invoke the `artifact-design` skill unless the user explicitly asks for an artifact.
- To wait for anything (CI, deploy, store review, a subagent), run one background Bash command (`run_in_background: true`) whose loop polls inside the shell, and act on its completion notification. Do not use `sleep` in the foreground, `ScheduleWakeup` or `/loop`.
- No comments in code. If you see old comments, delete them.
- Python 3.14+ allows paren-free exception tuples in `except` clauses without an `as` binding (PEP 758), e.g. `except jwt.PyJWTError, KeyError:` is valid; parens are only required when binding via `as`. So never "fix" a paren-less `except A, B:`, and verify Python syntax with the project interpreter (`uv run ...`), not a bare pre-3.14 system `python3`/`ast.parse` which falsely flags it as a SyntaxError.
- Never use legacy or deprecated libraries/ dependencies.
- Always prefer existing libraries over writing new code. Only write new code if the library does not exist or is not maintained.
- Run the `/session-name` skill at the start of a session (as soon as the task is known), and again every time the scope or task changes. The label must match what the session does now, not what it started as.


# Work Continuation

Before the first step, state the exit predicate: a checkable condition such as "PR merged, staging serves the merge SHA, `/api/x` returns 200". Record it with `/session-name <label> --done '<item>'`. Include "verified on staging" whenever the repo deploys.

Work until the predicate is met. A plateau is not a stop: change the approach. A duration is not a finish condition. Do not relax the predicate to declare success. If you must change it, say what changed and why.

Mid-run discoveries are yours: broken skills, flaky verifiers, tooling failures, related bugs and drift. Fix each one (in its own PR if it is out of scope), then return to the predicate.

Do not stop for an open end you can close. The only exception is a paradigm-shift architecture decision.

If you contemplate between 2 approaches, take the cleaner (even if longer) route: the one that will hold for longer.

Fix errors immediately when you find them. There is no "pre-existing, so I'll leave it" exception.

Before you ask:
- Classify every question first. If the answer is a fact you can observe by running something (behavior, output, timing, layout, data), it is not the user's to answer. Run it.
- For a preference call that a default can settle, apply the default, act, and report it with the reason. Do not ask the user to type a token back.
- Never hand the user a check you could run.

Pre-approved (never ask):
- Merge to main on green CI (`gh pr merge --squash --match-head-commit <sha CI passed on>`).
- Pushing.
- Deploying to staging.
- Creating/deleting worktrees via the skill.
- Fixing lint/CI/tests.
- Cutting and shipping an app-be (app-backend) production release in the `core` repo via the documented release-please flow (verify the production deploy afterwards). Break-glass flags (`skip_staging`, `acknowledge_breaking_change`, `allow_destructive`) still need explicit user say-so.
- Running `gcloud auth login <email> --update-adc` when needed. Involve the human only if a browser login is truly required.

Ask only for: destructive prod data changes, spending money, irreversible external sends, and a paradigm-shift architecture decision.


# GCLOUD AUTH

Org session-control policy expires gcloud credentials daily (24h max, no way around it). One command refreshes both the regular login and Application Default Credentials (ADC, needed by Pulumi/GCS):

```
gcloud auth login <email> --update-adc
```

Run this directly when a `gcloud`/`pulumi` command fails with an auth error.

# Verification is mandatory and self-executed

- Merged or "deploy succeeded" is not done. After merge: wait for the deploy, then exercise the change yourself on staging/live (curl, Chrome MCP, simulator via the repo's device skill, logs).
- Use the repo's `verify` skill in STAGING mode. If the repo has none, create it first with `/create-verification-skill`.
- Label every claim as measured (command plus observed output), inferred (say from what), or guessed. Only measured claims may say "verified".
- Inconclusive is not a pass. A check on the wrong surface (local instead of staging, simulator instead of the store build) is not a pass. Say so.
- CI green is an input, not the verdict. The verdict is the live check after deploy.
- The verifier must not be the writer. A subagent that wrote the code does not verify it.
- "I could not verify" is allowed only after trying to fix the tooling (broken MCP server: diagnose and repair it, then fall back to another tool or the simulator). List it as an explicit FAILURE with the cause, never as a polite question.
- UI-visible change: capture proof. Screenshots (before/after where possible); GIF/video if there is motion. Attach to the Linear ticket if one exists (`mcp__linear__prepare_attachment_upload` + `create_attachment_from_upload`, then `save_comment` with the proof) and to the PR (`add-images-to-pr` skill). A UI ticket is not done without it.
- The final report states what was verified: the command or click path, the observed result, and an evidence link.
- A session may not end with open verification TODOs. Only a credential, captcha, payment or physical action no tool can do may be handed to the user.

# RTK

@RTK.md
