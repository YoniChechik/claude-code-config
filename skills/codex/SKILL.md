---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network) by default; Recipe 4 is an opt-in full-access review mode the user must ask for."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

Codex runs are LONG (often many minutes, sometimes over an hour). This skill spawns **one dedicated subagent** whose entire job is: launch codex detached → block on a re-invoked poll loop until it exits → read the output → digest it → return a summary. The calling agent does not babysit codex and does not read raw codex output — it gets a finished summary back from the subagent.

## Mandatory flags (Recipes 1-3)

Recipe 4 ("Deep Review") deliberately changes `-C`, `--sandbox`, and `--skip-git-repo-check`. It is the **only** exception, it is opt-in, and it is spelled out in its own section below.

- **`-C /tmp`** — always run codex from `/tmp`, never from the caller's repo. Running codex inside a real project (e.g. one with `keyshelf.config.ts`, `.env.keyshelf`, `package.json` triggers, etc.) makes codex burn its first turn auto-discovering project skills and it often exits mid-reasoning instead of doing the actual analysis. Pass any project file paths as **absolute paths inside the prompt** — codex's read-only sandbox can still read them.
- **`--skip-git-repo-check`** — always set, since `/tmp` is not a git repo.
- **`--sandbox read-only`** — never relax this.
- **`-c approval_policy="never"`** — codex never prompts.
- **`-o <file>`** — always write output to a file; never consume stdout directly.

## Known gotcha: a prompt that names no file gets you a blind answer

**`-C /tmp --sandbox read-only` CAN read arbitrary absolute paths outside `/tmp`.** This was verified directly on codex-cli 0.146.0: given `Read the file /Users/<user>/core/CLAUDE.md and quote its first two lines`, codex ran `/bin/zsh -lc "sed -n '1,2p' /Users/<user>/core/CLAUDE.md"` from `/tmp` and quoted the file correctly. `read-only` restricts **writes** and **network**, not the read scope.

So if a codex answer comes back with "I could not read the repo" and zero `file:line` citations, the cause is almost always the **prompt**, not the sandbox: the prompt described files in prose and never told codex to open a specific absolute path, so codex answered from the prompt text plus general knowledge. **Every prompt must list the absolute paths codex is to read and instruct it to read them before answering.** Reserve Recipe 4 for when codex genuinely needs to run its own `grep`/`git log`/tests or reach the network — not as a fix for an underspecified prompt.

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

- **Always run from `/tmp` via `-C /tmp --skip-git-repo-check`.** Never `-C` into a real project directory — see the mandatory-flags rationale above. **Sole exception: Recipe 4.**
- **Always use `-o <file>`** to write output to a file. Never consume codex stdout directly.
- **The launch is always detached (`&`); the wait is always a blocking re-invoke poll loop inside the subagent.** The launcher subshell uses shell-level `&` (never `run_in_background=true`, which dies with the subagent). The WAIT is a foreground Bash poll call the subagent re-invokes until it prints `DONE`/`ABORTED` — never the async `Monitor` tool (it returns immediately and the subagent's turn would end before codex finishes). The subagent launches, polls in a re-invoke loop, digests, returns.
- **Never let the caller poll for codex.** The subagent owns the entire wait. The calling agent's only interaction is spawning it and reading its summary.
- Sandbox MUST be `read-only`, **except for Recipe 4** (see the named exception below). Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox` — the latter is banned in every recipe, Recipe 4 included, because it disables the sandbox *and* every approval path at once.
- **Named exception — Recipe 4 is the sole case where the sandbox is not `read-only`.** Recipe 4 uses `--sandbox danger-full-access` and is permitted **only when the user has explicitly asked, in that specific request, for codex to be given full access**. A calling agent must never choose it on its own initiative, never carry an older grant forward into a later request, and never reach for it because a `read-only` run produced a weak answer (that is the prompt gotcha above, not a sandbox limit). Under Recipe 4 the "codex must not write" guarantee is enforced by the **prompt**, not the sandbox — so the verbatim review-only instruction in that recipe is itself mandatory.
- Approval policy goes via `-c approval_policy="never"` — `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. In Recipes 1-3, any `gh`/`git fetch`/`curl` for gathering input must be run by Claude OUTSIDE codex, before the subagent is spawned, and written to a file codex reads by absolute path. (Recipe 4 has network access and can fetch its own.)
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

## Recipe 4: Deep Review — full read/web/bash access, review-only by instruction

**OPT-IN ONLY.** Use this recipe **only when the user has explicitly asked, in this request, to give codex full access.** It is not the default and never the fallback for a disappointing `read-only` run. Recipes 1-3 remain the safe default for normal reviews.

**What it is for.** A question codex cannot answer from a handful of quoted files: it needs to browse the real tree, run its own `grep` / `git log` / tests to verify a claim, and reach the network to find current primary sources instead of recalling training data.

**What changes from Recipes 1-3:**

- **`--sandbox danger-full-access`** — codex-cli's most permissive sandbox mode (`codex exec --help` lists exactly three: `read-only`, `workspace-write`, `danger-full-access`). It grants full read **and write** access, shell, and network. The "do not modify anything" guarantee comes from the **prompt**, not from the sandbox. Still **never** `--dangerously-bypass-approvals-and-sandbox`.
- **`-C <real repo or worktree path>`** instead of `/tmp` — codex works inside the actual tree, so `grep`, `git log`, and test runs resolve normally. Accept the cost the `/tmp` rule was avoiding: codex may spend its first turn on project skill discovery. Mitigate it with the `Do NOT invoke any skills.` line, which stays mandatory.
- **DROP `--skip-git-repo-check`** — a real repo/worktree is a git repo, so the flag is unnecessary.
- **KEEP `-c approval_policy="never"`** and **KEEP `-o <file>`** — unchanged.
- **Network is ON** — do not pre-fetch diffs or docs for codex; tell it to fetch them itself and cite real URLs.

**Launch shape** (the detached-launch + blocking-poll subagent machinery from Step 2 is unchanged; only the `codex exec` line differs):

```bash
codex exec --sandbox danger-full-access -c approval_policy="never" \
  -C /absolute/path/to/repo-or-worktree \
  -o "$OUT" \
  "$(cat "$PROMPT_FILE")"
```

**Prompt template.** The block below MUST appear **verbatim, near the top of the prompt**:

```
You are doing a READ-ONLY REVIEW. You have full tool access, but you must NOT create, modify, or delete any file, run any git command that changes state (commit/push/branch/checkout/reset), or make any destructive/mutating call. If you want to suggest a fix, describe it in your written output — do not apply it.
```

Then the review body:

```
Read these files before answering (absolute paths):
  /absolute/path/.../<file 1>
  /absolute/path/.../<file 2>
  ...

Use your own bash access to verify anything else you need — grep the tree, read
git history, run the relevant tests. Do not assume; check.

Use your own web access to find real, current primary sources. Cite actual URLs.
Do not cite claims recalled from training data as if they were sources.

Question: <the substantive question>

Give a final, concrete recommendation. Cite file:line for every claim about this
codebase, and a URL for every external claim. Flag explicitly anywhere your answer
differs from what a pure-reasoning pass with no code access would have concluded.

Do NOT invoke any skills.
```

**After the run.** Verify codex kept to review-only — the sandbox did not enforce it. Run `git status` and `git log --oneline -3` in the target worktree and confirm nothing changed beyond what you expect.
