---
name: "other-llm"
description: "Get an independent second opinion or delegate work to the OTHER coding CLI — whichever model family is NOT currently active. When the active model is an Anthropic/Claude model, run Codex; when the active model is OpenAI Codex (or another OpenAI model), run Claude. Use for independent reviews, plans, unfamiliar codebases, or hands-on implementation."
argument-hint: "[target or task]"
---

# Other LLM: second opinion or hands-on work via the other coding CLI

Delegate work to the coding CLI whose model family differs from the one running this session: a review, an exploration, or real work (commands, changes). The other CLI always runs with full access. The prompt, not a sandbox flag, says what it may do.

## Step 1: pick the runner

1. Identify the active model family for this session (an env var or session context field usually names it).
2. Anthropic/Claude active: the runner is `codex`.
3. OpenAI Codex (or another OpenAI model) active: the runner is `claude`.
4. If the family cannot be determined from the session context, the runner is `codex` when `claude` is the CLI you run in, else `claude`.

## Step 2: build the prompt

Reference every file by absolute path. Tell the runner plainly what it may do:

- **Review only**: prepend "You are doing a READ-ONLY REVIEW. Do not create, modify, or delete any file, or run any state-changing git command (commit/push/branch/checkout/reset). Describe fixes in your output; don't apply them."
- **Do it**: describe the real task (implement X, run Y, fix Z). No restriction needed.

Either way, add `Do NOT invoke any skills.` The runner otherwise burns its first turn on skill discovery. The runner has network access. Let it fetch a PR diff or docs itself, unless this session already has the data in hand.

Write the prompt to `<run-dir>/prompt.md`, where `<run-dir>` is a new directory in your scratchpad (or `mktemp -d` when there is no scratchpad).

## Step 3: run it as one background watcher

Run this with the Bash tool, `run_in_background: true`, and no `timeout` override. Runs take minutes to over an hour.

```bash
bash "<skill-base-dir>/run.sh" <codex|claude> "<cwd>" "<run-dir>/prompt.md" "<run-dir>"
```

- `<cwd>` is the repo or worktree the runner works in. Use the scratchpad only when there is no relevant repo.
- The script starts the runner with `</dev/null` on the runner's own command line, polls inside the shell, and exits when the runner exits. It prints `DONE exit=<code> out=<run-dir>/out.md stderr=<run-dir>/stderr.log`.
- Stall check: if stderr ends with "Reading additional input from stdin" for over 30 s, the script kills the runner and relaunches it once. A second stall exits 124 with `STALLED twice on stdin`.
- Act on the completion notification. Do not poll it with `sleep`, `ScheduleWakeup` or `/loop`. Do not wrap the runner in `timeout` or `gtimeout`.

## Step 4: digest and act

1. Read `<run-dir>/out.md`. If it is empty, the exit code is non-zero, or the run stalled, read `<run-dir>/stderr.log` and say what went wrong.
2. Summarize the runner's findings or actions, most important first, with `file:line` citations and your own read on which look solid or weak.
3. Review mode: apply the fixes this session agrees with. The runner made none.
4. Do-it mode: check what changed (`git status`, `git log --oneline -3` in `<cwd>`). The summary is a claim; the repo state is the evidence.

## Rules

- Codex runner: always `--sandbox danger-full-access -c approval_policy="never" -o <file>`, as `run.sh` does. Never `--dangerously-bypass-approvals-and-sandbox`: it disables the sandbox and every approval path at once, and the prompt already carries the real restriction.
- Set `OTHER_LLM_MODEL=<model>` on the `run.sh` call to pass `-m <model>` to Codex, only if the user asks.
- Do not invoke skills inside the delegated prompt. Let the other CLI inspect the repository and fetch public documentation itself.
