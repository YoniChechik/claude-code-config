---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

Codex runs are LONG (often many minutes, sometimes over an hour). This skill spawns **one dedicated subagent** whose entire job is: launch codex detached → monitor until it exits → read the output → digest it → return a summary. The calling agent does not babysit codex and does not read raw codex output — it gets a finished summary back from the subagent.

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

## Step 2: wait for codex with the Monitor tool

Call Monitor with `timeout_ms: 3600000` (the maximum), `persistent: false`, and a
`description` like "codex run <RUN_ID>". Substitute the real paths into this command:

```bash
DONE="<DONE>"; OUT="<OUT>"; STDERR="<STDERR>"; PID="<PID>"

# Emit exactly ONE line on ANY terminal state, then exit -- exiting ends the watch.
# Silence is not success: this loop must break on failure as well as on success, or a
# SIGKILLed codex would look identical to a still-running one.
while true; do
  # Terminal state 1: codex exited and published its exit code.
  if [[ -f "$DONE" ]]; then
    echo "codex finished exit=$(cat "$DONE") out=$OUT"; break
  fi
  # Terminal state 2: the launcher subshell vanished without ever writing a marker
  # (SIGKILL / OOM / reboot). Grace window covers the marker landing between checks.
  if ! kill -0 "$PID" 2>/dev/null; then
    sleep 2
    if [[ -f "$DONE" ]]; then echo "codex finished exit=$(cat "$DONE") out=$OUT"
    else echo "codex ABORTED: pid $PID gone, no done-marker. stderr=$STDERR"; fi
    break
  fi
  sleep 5
done
```

If Monitor times out after the full hour with no event, just re-arm it with the same
command. Re-arming is safe and idempotent: the loop checks the done-marker first, so a
run that finished during the gap is picked up on the next iteration's first check.

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
- **The launch is always detached (`&`) and always monitored from inside the subagent.** Never `run_in_background=true` (it dies with the subagent) and never a blocking foreground Bash call (10 min cap, codex runs exceed it). The subagent launches, Monitors, digests, returns.
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
