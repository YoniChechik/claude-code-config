---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

Codex runs are LONG (often many minutes, sometimes over an hour). This skill spawns **one dedicated subagent** whose entire job is: launch codex detached → block on a re-invoked poll loop until it exits → read the output → digest it → return a summary. The calling agent does not babysit codex and does not read raw codex output — it gets a finished summary back from the subagent.

## Mandatory flags

- **`-C /tmp`** — always run codex from `/tmp`, never from the caller's repo. Running codex inside a real project (e.g. one with `keyshelf.config.ts`, `.env.keyshelf`, `package.json` triggers, etc.) makes codex burn its first turn auto-discovering project skills and it often exits mid-reasoning instead of doing the actual analysis. Pass any project file paths as **absolute paths inside the prompt** — codex's read-only sandbox can still read them.
- **`--skip-git-repo-check`** — always set, since `/tmp` is not a git repo.
- **`--sandbox read-only`** — never relax this.
- **`-c approval_policy="never"`** — codex never prompts.
- **`-o <file>`** — always write output to a file; never consume stdout directly.

## Step 1: build the review prompt

Pick a recipe below (or write your own). Reference every project file by **absolute path** — codex is running from `/tmp` and has no network, so anything it needs must already exist on disk.

If the recipe needs data from the network (a PR diff, a remote file), **fetch it yourself now**, before spawning the subagent — see Recipe 3.

## Step 2: spawn the watcher subagent

Use the Agent tool with `subagent_type: general-purpose` and `model: "opus"`. Leave it in the background (the default) so you are not blocked — you get notified when it completes and returns its summary. Only pass `run_in_background: false` if you genuinely cannot proceed without codex's verdict.

The subagent has zero memory of your session — the prompt must be fully self-contained. Embed the template below verbatim, substituting only the review prompt.

### Subagent prompt template

````
You are a codex run supervisor. Your entire job: launch codex detached, wait for it to
finish, read its output, and return a digested summary. Do NOT edit any files. Do NOT
apply any fixes. Do NOT invoke other skills.

## Step 1: launch codex detached (run this Bash call verbatim)

```bash
RUN_ID="codex-$(date +%s%N)"
PROMPT_FILE="/tmp/${RUN_ID}-prompt.md"
OUT="/tmp/${RUN_ID}-out.md"
STDERR="/tmp/${RUN_ID}-stderr.log"
DONE="/tmp/${RUN_ID}-done"

# Write the prompt to a file: avoids quoting hell and lets prompts be arbitrarily large.
cat >"$PROMPT_FILE" <<'EOF'
<<<REVIEW_PROMPT>>>
EOF

# Detached background subshell. MUST use shell-level `&`, NOT the Bash tool's
# run_in_background=true: run_in_background ties the process to this subagent's
# lifetime and kills codex the moment the subagent exits. A foreground call is also
# wrong -- it caps at 600000ms (10 min) and codex runs routinely exceed that.
# A detached `&` subshell survives independently for as long as codex needs.
(
  codex exec --sandbox read-only -c approval_policy="never" \
    -C /tmp --skip-git-repo-check \
    -o "$OUT" \
    "$(cat "$PROMPT_FILE")"
  # Publish codex's exit code via an atomic done-marker: write to .tmp then mv, so the
  # watcher can never observe a half-written marker.
  echo "$?" > "${DONE}.tmp" && mv "${DONE}.tmp" "$DONE"
) </dev/null >>"$STDERR" 2>&1 &

# $! is the subshell's PID, not codex's. That is what we want: it is the liveness proxy
# for the whole run, so we can detect a SIGKILL that prevents the marker from ever landing.
echo "$!" > "/tmp/${RUN_ID}-pid"
echo "RUN_ID=$RUN_ID PID=$(cat "/tmp/${RUN_ID}-pid") OUT=$OUT STDERR=$STDERR DONE=$DONE"
```

This call returns immediately. Record RUN_ID / OUT / STDERR / DONE from its output.

## Step 2: wait for codex with a BLOCKING re-invoke poll loop

Wait by calling the poll command below as a **foreground** Bash tool call (NOT
`run_in_background`, NOT the Monitor tool — see why below). Each call BLOCKS your turn
for up to ~9 minutes, then prints exactly one verdict. This is a RE-INVOKE loop: if the
verdict is `STILL_RUNNING`, you IMMEDIATELY call the exact same Bash command AGAIN, and
keep re-calling it until you get `DONE` or `ABORTED`. Every re-call is a real tool call,
so your turn stays alive across the whole wait.

Substitute the real paths recorded from Step 1 into this command:

```bash
DONE="<DONE>"; OUT="<OUT>"; STDERR="<STDERR>"; PID="<PID>"

# Bounded blocking poll: up to 540 iterations of a 1-second sleep (~9 min of real
# waiting), kept safely under the foreground Bash 600000ms/10-min cap. Print ONE verdict
# and exit 0 the instant a terminal state is known. Silence is never success -- every
# branch below prints, so a SIGKILLed codex can never masquerade as still-running.
for i in $(seq 1 540); do
  # Terminal state 1: codex exited and published its exit code via the done-marker.
  if [[ -f "$DONE" ]]; then
    echo "DONE exit=$(cat "$DONE") out=$OUT"; exit 0
  fi
  # Terminal state 2: the launcher subshell vanished without ever writing a marker
  # (SIGKILL / OOM / reboot). A 1s grace re-check covers the marker landing right at
  # the moment the subshell exited.
  if ! kill -0 "$PID" 2>/dev/null; then
    sleep 1
    if [[ -f "$DONE" ]]; then echo "DONE exit=$(cat "$DONE") out=$OUT"
    else echo "ABORTED: pid $PID gone, no done-marker. stderr=$STDERR"; fi
    exit 0
  fi
  # Not terminal yet: wait one second and re-check. 1-second interval ONLY -- never a
  # long blocking sleep.
  sleep 1
done
# Hit the ~9-min cap with codex still alive and no marker: it is simply still running.
# Report that so the supervisor re-invokes this SAME command to keep waiting.
echo "STILL_RUNNING pid=$PID (codex still running; re-invoke this poll command)"
```

Act on the verdict:

- **`DONE exit=<code> ...`** — codex finished. Proceed to Step 3.
- **`ABORTED: ...`** — the launcher died with no marker. Proceed to Step 3 and diagnose
  via `$STDERR`.
- **`STILL_RUNNING ...`** — the poll hit its ~9-min cap before codex finished. You MUST
  immediately call the EXACT SAME poll Bash command again. Do this as many times as it
  takes; codex runs can exceed an hour, i.e. many re-invocations.

CRITICAL — this is a RE-INVOKE loop, NOT fire-and-forget. You MUST NOT end your turn
while the last poll printed `STILL_RUNNING`: that means codex is still running and you
owe another poll call. Only a `DONE` or `ABORTED` verdict lets you move to Step 3.

Do NOT use the `Monitor` tool to wait here. `Monitor` is asynchronous — it arms a
background watcher and returns immediately without blocking your turn. If you armed it
and stopped, your turn would end (marked `completed`) before codex finished, and the
completion notification would be lost because a terminated subagent is not reliably
re-invoked. The blocking re-invoke poll above is the required path.

## Step 3: digest and return

1. Read `$OUT` with the Read tool.
2. If `$OUT` is empty/missing, the exit code is non-zero, or the run ABORTED — read
   `$STDERR` to diagnose, and say plainly what went wrong.
3. Return a summary as your final message. Include:
   - Codex's substantive findings, most important first, with the `file:line` citations
     codex gave. Drop its filler and restate its reasoning tightly.
   - Your own read on which findings look solid vs. wrong or low-value — you have seen
     the code; say so if codex is off base.
   - The `$OUT` path, so the caller can read the raw output if it wants more detail.
   Do NOT write a report file — your final message IS the deliverable.

## The review prompt for codex

<<<REVIEW_PROMPT>>>
````

`-m <model>` overrides codex's default model — do NOT add it unless the user asks.

## Step 3: act on the subagent's summary

When the subagent returns:

1. **Summarize** codex's findings back to the user.
2. **Apply any fixes** Claude agrees with — codex itself made no changes.

## Rules (non-negotiable)

- **Always run from `/tmp` via `-C /tmp --skip-git-repo-check`.** Never `-C` into a real project directory — see the mandatory-flags rationale above.
- **Always use `-o <file>`** to write output to a file. Never consume codex stdout directly.
- **The launch is always detached (`&`); the wait is always a blocking re-invoke poll loop inside the subagent.** The launcher subshell uses shell-level `&` (never `run_in_background=true`, which dies with the subagent). The WAIT is a foreground Bash poll call the subagent re-invokes until it prints `DONE`/`ABORTED` — never the async `Monitor` tool (it returns immediately and the subagent's turn would end before codex finishes). The subagent launches, polls in a re-invoke loop, digests, returns.
- **Never let the caller poll for codex.** The subagent owns the entire wait. The calling agent's only interaction is spawning it and reading its summary.
- Sandbox MUST be `read-only`. Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox`.
- Approval policy goes via `-c approval_policy="never"` — `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. Any `gh`/`git fetch`/`curl` for gathering input must be run by Claude OUTSIDE codex, before the subagent is spawned, and written to a file codex reads by absolute path.
- Codex never writes. If codex suggests fixes, Claude applies them.

## Recipe 1: Codebase Exploration

Claude has a question about unfamiliar code and wants a second pair of eyes. Pass the repo root as an **absolute path inside the prompt**, not via `-C` (always keep `-C /tmp`).

```
Explore the repo rooted at /absolute/path/to/repo and explain <question>.
List the key files involved (absolute paths). Do NOT invoke any skills.
```

## Recipe 2: Plan / Design .md Review

Have codex stress-test a design doc for missing considerations. Reference the plan by absolute path:

```
Review the plan at /absolute/path/to/plan.md. Flag missing considerations,
risks, or unclear steps. Do NOT invoke any skills.
```

## Recipe 3: PR Diff Review

Codex cannot reach GitHub. Fetch the diff yourself first — before spawning the subagent — then reference it by absolute path in the prompt:

```bash
DIFF_FILE="/tmp/codex-diff-$(date +%s%N).txt"
# Pre-fetch outside codex — codex has no network.
{ gh pr view <NUM> --json title,body,files; echo '---DIFF---'; gh pr diff <NUM>; } > "$DIFF_FILE"
```

Then use a prompt like:

```
Review the PR. Metadata then diff in /tmp/codex-diff-<...>.txt.
Focus on correctness, edge cases, and security. Cite file:line.
Do NOT invoke any skills.
```
