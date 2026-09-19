---
name: "other-llm"
description: "Get an independent second opinion or delegate work to the OTHER coding CLI — whichever model family is NOT currently active. When the active model is an Anthropic/Claude model, run Codex; when the active model is OpenAI Codex (or another OpenAI model), run Claude. Use for independent reviews, plans, unfamiliar codebases, or hands-on implementation."
argument-hint: "[target or task]"
---

# Other LLM: Second Opinion / Hands-On via the Other Coding CLI

Delegate work to whichever coding CLI is backed by a DIFFERENT model family
from the one currently running this session — a review, an exploration, or
actually doing something (running commands, making changes). The other CLI
always runs with full access; what it's allowed to do comes from the
**prompt**, not a sandbox flag.

## Step 1: pick the runner

1. Identify the active model/provider for this session (in a multi-provider
   tool, an env var or session context field typically names it directly).
2. If the active model is Anthropic/Claude, the runner is `codex`.
3. If the active model is OpenAI Codex (or another OpenAI model), the runner
   is `claude`.
4. If the active model family can't be determined, ask the user which CLI to
   use. Do not guess.

Everything below is written for `codex` as the runner, since that is the
common case (this session IS Claude). If Step 1 selected `claude` instead,
run the equivalent `claude` invocation — same detach/poll/digest shape, just
`claude -p --no-session-persistence "<prompt>"` in place of the `codex exec
...` command below, with no `--sandbox`/`--output-format` flags (those are
Codex-specific).

These runs are LONG (minutes, sometimes over an hour). This skill spawns
**one dedicated subagent** whose entire job is: launch the runner detached →
block on a re-invoked poll loop until it exits → read the output → digest it
→ return a summary. The calling agent never babysits the runner directly.

## Step 2: build the prompt

Reference every file by absolute path. Tell the runner plainly what it may do:

- **Review only**: prepend "You are doing a READ-ONLY REVIEW. Do not create,
  modify, or delete any file, or run any state-changing git command
  (commit/push/branch/checkout/reset). Describe fixes in your output — don't
  apply them."
- **Do it**: just describe the real task — implement X, run Y, fix Z. No
  restriction needed.

Either way, add `Do NOT invoke any skills.` — the runner otherwise burns its
first turn on project-skill discovery. The runner has network access; let it
fetch a PR diff/docs itself rather than pre-fetching, unless this session
already has the data in hand.

## Step 3: spawn the watcher subagent

Use the Agent tool, `subagent_type: general-purpose`, `model: "opus"`,
backgrounded (the default). The subagent has zero memory of this session —
embed the template below verbatim, substituting only the prompt and the `-C`
path (the repo/worktree the runner should work in — use `/tmp` only when
there's no relevant repo).

### Subagent prompt template (codex runner)

````
You are a runner supervisor. Your entire job: launch the runner detached, wait for it to
finish, read its output, and return a digested summary. Do NOT edit any files yourself.
Do NOT apply any fixes. Do NOT invoke other skills.

## Step 1: launch the runner detached (run this Bash call verbatim)

```bash
RUN_ID="otherllm-$(date +%s%N)"
PROMPT_FILE="/tmp/${RUN_ID}-prompt.md"
OUT="/tmp/${RUN_ID}-out.md"
STDERR="/tmp/${RUN_ID}-stderr.log"
DONE="/tmp/${RUN_ID}-done"

cat >"$PROMPT_FILE" <<'EOF'
<<<PROMPT>>>
EOF

# Detached background subshell. MUST use shell-level `&`, NOT the Bash tool's
# run_in_background=true (which dies with this subagent). A foreground call is also
# wrong -- it caps at 600000ms and these runs routinely exceed that.
(
  codex exec --sandbox danger-full-access -c approval_policy="never" \
    -C "<<<CWD>>>" \
    -o "$OUT" \
    "$(cat "$PROMPT_FILE")"
  echo "$?" > "${DONE}.tmp" && mv "${DONE}.tmp" "$DONE"
) </dev/null >>"$STDERR" 2>&1 &

echo "$!" > "/tmp/${RUN_ID}-pid"
echo "RUN_ID=$RUN_ID PID=$(cat "/tmp/${RUN_ID}-pid") OUT=$OUT STDERR=$STDERR DONE=$DONE"
```

This call returns immediately. Record RUN_ID / OUT / STDERR / DONE from its output.

## Step 2: wait with a BLOCKING re-invoke poll loop

Wait by calling the poll command below as a **foreground** Bash tool call (NOT
`run_in_background`, NOT the Monitor tool). Each call BLOCKS your turn for up to
~9 minutes, then prints exactly one verdict. This is a RE-INVOKE loop: if the verdict
is `STILL_RUNNING`, you IMMEDIATELY call the exact same command again, and keep
re-calling it until you get `DONE` or `ABORTED`.

Substitute the real paths recorded from Step 1:

```bash
DONE="<DONE>"; OUT="<OUT>"; STDERR="<STDERR>"; PID="<PID>"

for i in $(seq 1 540); do
  if [[ -f "$DONE" ]]; then
    echo "DONE exit=$(cat "$DONE") out=$OUT"; exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    sleep 1
    if [[ -f "$DONE" ]]; then echo "DONE exit=$(cat "$DONE") out=$OUT"
    else echo "ABORTED: pid $PID gone, no done-marker. stderr=$STDERR"; fi
    exit 0
  fi
  sleep 1
done
echo "STILL_RUNNING pid=$PID (runner still running; re-invoke this poll command)"
```

Act on the verdict:
- **`DONE exit=<code> ...`** — the runner finished. Proceed to Step 3.
- **`ABORTED: ...`** — the launcher died with no marker. Proceed to Step 3 and diagnose
  via `$STDERR`.
- **`STILL_RUNNING ...`** — you MUST immediately call the EXACT SAME poll command again,
  as many times as it takes; these runs can exceed an hour.

CRITICAL: you must NOT end your turn while the last poll printed `STILL_RUNNING`.
Never use `Monitor` here — it returns immediately and your turn would end before the
runner finishes.

## Step 3: digest and return

1. Read `$OUT` with the Read tool.
2. If `$OUT` is empty/missing, exit code non-zero, or ABORTED — read `$STDERR` to
   diagnose, and say plainly what went wrong.
3. Return a summary as your final message: the runner's substantive findings/actions,
   most important first, with any `file:line` citations; your own read on which look
   solid vs. weak; and the `$OUT` path. Do NOT write a report file.

## The prompt for the runner

<<<PROMPT>>>
````

For the `claude` runner (active model is Codex), replace Step 1's launch command with:
```bash
(
  claude -p --no-session-persistence -C "<<<CWD>>>" "$(cat "$PROMPT_FILE")" >"$OUT"
  echo "$?" > "${DONE}.tmp" && mv "${DONE}.tmp" "$DONE"
) </dev/null >>"$STDERR" 2>&1 &
```
Everything else (poll loop, digest) is identical.

`-m <model>` overrides the runner's default model — only if the user asks (Codex only).

## Step 4: act on the subagent's summary

1. Summarize the runner's findings/actions back to the user.
2. Review mode: apply any fixes this session agrees with — the runner made none itself.
3. Do-it mode: verify what actually changed — `git status` / `git log --oneline -3`
   in the target directory. The sandbox didn't enforce anything; the summary and this
   check are what confirm the runner did what it was asked.

## Rules

- Always `-C <the real repo/worktree path>`; `/tmp` only when there's no relevant repo.
- Codex runner: always `--sandbox danger-full-access -c approval_policy="never" -o <file>`.
  Never `--dangerously-bypass-approvals-and-sandbox` — that disables the sandbox *and*
  every approval path at once, which this skill doesn't need since the prompt already
  carries the real restriction.
- Launch detached (shell `&`, never Bash tool `run_in_background`). Wait only via the
  subagent's blocking re-invoke poll loop — never let the calling agent poll directly.
- Do not invoke skills inside the delegated prompt. Let the other CLI inspect the
  repository and fetch any needed public documentation itself.
