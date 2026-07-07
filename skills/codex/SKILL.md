---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

Codex runs are LONG (often many minutes). Rather than block the calling agent on a foreground poll-wait, this skill launches codex **detached in the background** and has it **notify the session via the webhook channel when it finishes** — exactly the pattern the CI watcher uses. The launch Bash call returns immediately; you do NOT block. When codex completes you receive a `<channel source="webhook">` message telling you to Read the output file.

> **Subagent-safe by design.** This skill is called from both the main agent and subagents. Subagents are killed shortly after their final tool call returns, so the Bash tool's `run_in_background=true` would kill codex prematurely (the background process is tied to the subagent's lifetime). The launcher below uses **shell-level `&` backgrounding** so the detached subshell survives independently — the same recipe works identically in both contexts. Do NOT "optimize" this to `run_in_background=true`; it breaks subagent callers.

## Mandatory flags

- **`-C /tmp`** — always run codex from `/tmp`, never from the caller's repo. Running codex inside a real project (e.g. one with `keyshelf.config.ts`, `.env.keyshelf`, `package.json` triggers, etc.) makes codex burn its first turn auto-discovering project skills and it often exits mid-reasoning instead of doing the actual analysis. Pass any project file paths as **absolute paths inside the prompt** — codex's read-only sandbox can still read them.
- **`--skip-git-repo-check`** — always set, since `/tmp` is not a git repo.
- **`--sandbox read-only`** — never relax this.
- **`-c approval_policy="never"`** — codex never prompts.
- **`-o <file>`** — always write output to a file; never consume stdout directly.

## Step 1: get the webhook HTTP port (REQUIRED FIRST STEP)

Call the `mcp__webhook__get_port` MCP tool (from the webhook server). It returns `PORT:TOKEN` format.
Parse the result: everything before the first `:` is `$PORT`, everything after is `$SESSION_TOKEN`.

Only `$PORT` is needed to send the completion notification — the webhook `/` POST endpoint takes the request body verbatim as the notification content and requires no auth. (`$SESSION_TOKEN` is only used by the webhook `/health` check; you don't need it here.)

## Step 2: launch codex detached + notify-on-completion (use verbatim)

Substitute the `PORT` value from step 1. This Bash call **returns immediately** — do NOT set a long `timeout`, and do NOT poll-wait; the webhook notification replaces all of that.

```bash
# The webhook is session-keyed — bail if the harness didn't inject the session id.
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "Error: CLAUDE_CODE_SESSION_ID is unset; cannot notify on completion." >&2
    exit 1
fi

PORT="<PORT from mcp__webhook__get_port — the part before the first ':'>"

PROMPT_FILE="/tmp/codex-prompt-$(date +%s%N).md"
OUT="/tmp/codex-out-$(date +%s%N).md"
STDERR="/tmp/codex-stderr-$(date +%s%N).log"

# Write the prompt to a file (avoids quoting hell, lets prompts be arbitrarily large).
cat >"$PROMPT_FILE" <<'EOF'
READ-ONLY review. Do NOT invoke any skills.
<review prompt here — reference any project files by ABSOLUTE path>
EOF

# Detached background subshell: run codex, then POST a completion notice to the
# webhook HTTP server. MUST use shell-level `&` (NOT the Bash tool's
# run_in_background=true): when the caller is a subagent, run_in_background dies
# the moment the subagent exits, killing codex mid-run. A detached `&` subshell
# survives independently, so codex finishes and the notification always fires.
(
  codex exec --sandbox read-only -c approval_policy="never" \
    -C /tmp --skip-git-repo-check \
    -o "$OUT" \
    "$(cat "$PROMPT_FILE")"
  CODEX_EXIT=$?
  # Notify the session that codex is done. Same mechanism ci_watch.py uses:
  # a plain POST to the webhook's localhost port; the raw request body becomes
  # the notification message (no auth token, no special headers).
  curl -sS -X POST --data-binary \
    "codex finished (exit=$CODEX_EXIT). Read the output file with the Read tool: $OUT (stderr on error: $STDERR)" \
    "http://127.0.0.1:${PORT}/" >/dev/null 2>&1
) </dev/null >>"$STDERR" 2>&1 &

echo "codex launched detached (PID $!). Will notify via webhook when done. out=$OUT stderr=$STDERR"
```

`-m <model>` overrides the default model — do NOT set unless the user asks.

## Step 3: do NOT block — wait for the webhook

After the launch Bash call returns, **do not poll and do not run any waiting loop**. Go do other work or yield. When codex finishes you will receive a `<channel source="webhook">` message containing the `$OUT` path. Only then:

1. **Read the output file** using the Read tool at the `$OUT` path from the message.
2. If `$OUT` is empty or the reported exit code is non-zero, read `$STDERR` to diagnose.
3. **Summarize** codex's findings back to the user.
4. **Apply any fixes** Claude agrees with — codex itself made no changes.

## Rules (non-negotiable)

- **Always run from `/tmp` via `-C /tmp --skip-git-repo-check`.** Never `-C` into a real project directory — see the mandatory-flags rationale above.
- **Always use `-o <file>`** to write output to a file. Never consume codex stdout directly.
- **Never use `run_in_background=true`** on the Bash tool. Use shell-level `&` as shown. This is required for subagent compatibility.
- **Do NOT block the launch Bash call.** No `timeout: 600000`, no `MAX_BATCHES` poll-wait loop — the webhook notification tells you when codex is done. The launch call must return immediately.
- Sandbox MUST be `read-only`. Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox`.
- Approval policy goes via `-c approval_policy="never"` — `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. Any `gh`/`git fetch`/`curl` for gathering input must be run by Claude OUTSIDE codex and piped into codex via stdin (or written to a file codex reads). (The completion-notify `curl` above runs in the OUTER subshell, after codex exits — not inside the sandbox.)
- Codex never writes. If codex suggests fixes, Claude applies them.

## Recipe 1: Codebase Exploration

Claude has a question about unfamiliar code and wants a second pair of eyes. Pass the repo root as an **absolute path inside the prompt**, not via `-C` (always keep `-C /tmp`).

Use the launcher above with a prompt like:

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

Codex cannot reach GitHub. Claude fetches the diff first, writes it to a temp file, then references it by absolute path in the prompt:

```bash
DIFF_FILE="/tmp/codex-diff-$(date +%s%N).txt"
# Pre-fetch outside codex — codex has no network.
{ gh pr view <NUM> --json title,body,files; echo '---DIFF---'; gh pr diff <NUM>; } > "$DIFF_FILE"
```

Then invoke codex with the launcher and a prompt like:

```
Review the PR. Metadata then diff in /tmp/codex-diff-<...>.txt.
Focus on correctness, edge cases, and security. Cite file:line.
Do NOT invoke any skills.
```
