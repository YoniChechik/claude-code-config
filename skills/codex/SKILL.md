---
name: "codex"
description: "Use when Claude wants a second opinion or hands-on help from OpenAI Codex CLI — reviewing code/plans/PRs, exploring an unfamiliar codebase, or actually running/implementing something. Codex always runs with full read/write/bash/network access; the prompt tells it whether this is review-only or a real task."
argument-hint: "[target or task]"
---

# Codex: Second Opinion / Hands-On via OpenAI Codex CLI

Delegate work to the `codex` CLI — a review, an exploration, or actually doing
something (running commands, making changes). Codex always runs with full
access; what it's allowed to do comes from the **prompt**, not a sandbox flag.

Codex runs are LONG (minutes, sometimes over an hour). This skill spawns
**one dedicated subagent** whose entire job is: launch codex detached → block
on a re-invoked poll loop until it exits → read the output → digest it →
return a summary. The calling agent never babysits codex directly.

## Step 1: build the prompt

Reference every file by absolute path. Tell codex plainly what it may do:

- **Review only**: prepend "You are doing a READ-ONLY REVIEW. Do not create,
  modify, or delete any file, or run any state-changing git command
  (commit/push/branch/checkout/reset). Describe fixes in your output — don't
  apply them."
- **Do it**: just describe the real task — implement X, run Y, fix Z. No
  restriction needed.

Either way, add `Do NOT invoke any skills.` — codex otherwise burns its first
turn on project-skill discovery. Codex has network access; let it fetch a PR
diff/docs itself rather than pre-fetching, unless Claude already has the data
in hand.

## Step 2: spawn the watcher subagent

Use the Agent tool, `subagent_type: general-purpose`, `model: "opus"`,
backgrounded (the default). The subagent has zero memory of this session —
embed the template below verbatim, substituting only the prompt and the `-C`
path (the repo/worktree codex should work in — use `/tmp` only when there's
no relevant repo).

### Subagent prompt template

````
You are a codex run supervisor. Your entire job: launch codex detached, wait for it to
finish, read its output, and return a digested summary. Do NOT edit any files yourself.
Do NOT apply any fixes. Do NOT invoke other skills.

## Step 1: launch codex detached (run this Bash call verbatim)

```bash
RUN_ID="codex-$(date +%s%N)"
PROMPT_FILE="/tmp/${RUN_ID}-prompt.md"
OUT="/tmp/${RUN_ID}-out.md"
STDERR="/tmp/${RUN_ID}-stderr.log"
DONE="/tmp/${RUN_ID}-done"

cat >"$PROMPT_FILE" <<'EOF'
<<<PROMPT>>>
EOF

# Detached background subshell. MUST use shell-level `&`, NOT the Bash tool's
# run_in_background=true (which dies with this subagent). A foreground call is also
# wrong -- it caps at 600000ms and codex runs routinely exceed that.
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

## Step 2: wait for codex with a BLOCKING re-invoke poll loop

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
echo "STILL_RUNNING pid=$PID (codex still running; re-invoke this poll command)"
```

Act on the verdict:
- **`DONE exit=<code> ...`** — codex finished. Proceed to Step 3.
- **`ABORTED: ...`** — the launcher died with no marker. Proceed to Step 3 and diagnose
  via `$STDERR`.
- **`STILL_RUNNING ...`** — you MUST immediately call the EXACT SAME poll command again,
  as many times as it takes; codex runs can exceed an hour.

CRITICAL: you must NOT end your turn while the last poll printed `STILL_RUNNING`.
Never use `Monitor` here — it returns immediately and your turn would end before codex
finishes.

## Step 3: digest and return

1. Read `$OUT` with the Read tool.
2. If `$OUT` is empty/missing, exit code non-zero, or ABORTED — read `$STDERR` to
   diagnose, and say plainly what went wrong.
3. Return a summary as your final message: codex's substantive findings/actions, most
   important first, with any `file:line` citations; your own read on which look solid
   vs. weak; and the `$OUT` path. Do NOT write a report file.

## The prompt for codex

<<<PROMPT>>>
````

`-m <model>` overrides codex's default model — only if the user asks.

## Step 3: act on the subagent's summary

1. Summarize codex's findings/actions back to the user.
2. Review mode: apply any fixes Claude agrees with — codex made none itself.
3. Do-it mode: verify what actually changed — `git status` / `git log --oneline -3`
   in the target directory. The sandbox didn't enforce anything; the summary and this
   check are what confirm codex did what it was asked.

## Rules

- Always `-C <the real repo/worktree path>`; `/tmp` only when there's no relevant repo.
- Always `--sandbox danger-full-access -c approval_policy="never" -o <file>`. Never
  `--dangerously-bypass-approvals-and-sandbox` — that disables the sandbox *and* every
  approval path at once, which this skill doesn't need since the prompt already carries
  the real restriction.
- Launch detached (shell `&`, never Bash tool `run_in_background`). Wait only via the
  subagent's blocking re-invoke poll loop — never let the calling agent poll directly.
