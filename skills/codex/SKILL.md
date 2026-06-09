---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

> **Subagent vs main-agent compatibility note.** This skill is called from both the main agent and subagents. Subagents are killed shortly after their final tool call returns, which means `run_in_background=true` on the Bash tool would kill codex prematurely (the background process is tied to the subagent's lifetime). The canonical invocation below uses **shell-level backgrounding + a foreground poll-wait** so the same recipe works identically in both contexts. Do not "optimize" this back to `run_in_background=true` — it breaks subagent callers.

## Mandatory flags

- **`-C /tmp`** — always run codex from `/tmp`, never from the caller's repo. Running codex inside a real project (e.g. one with `keyshelf.config.ts`, `.env.keyshelf`, `package.json` triggers, etc.) makes codex burn its first turn auto-discovering project skills and it often exits mid-reasoning instead of doing the actual analysis. Pass any project file paths as **absolute paths inside the prompt** — codex's read-only sandbox can still read them.
- **`--skip-git-repo-check`** — always set, since `/tmp` is not a git repo.
- **`--sandbox read-only`** — never relax this.
- **`-c approval_policy="never"`** — codex never prompts.
- **`-o <file>`** — always write output to a file; never consume stdout directly.

## Invocation Template (use verbatim)

```bash
PROMPT_FILE="/tmp/codex-prompt-$(date +%s%N).md"
OUT="/tmp/codex-out-$(date +%s%N).md"
STDERR="/tmp/codex-stderr-$(date +%s%N).log"

# Write the prompt to a file (avoids quoting hell, lets prompts be arbitrarily large).
cat >"$PROMPT_FILE" <<'EOF'
<review prompt here — reference any project files by ABSOLUTE path>
EOF

# Shell-level backgrounding so this works identically from main agent AND subagents.
# Do NOT use run_in_background=true on the Bash tool — it kills codex when a subagent exits.
codex exec --sandbox read-only -c approval_policy="never" \
  -C /tmp --skip-git-repo-check \
  -o "$OUT" \
  "$(cat "$PROMPT_FILE")" \
  </dev/null >"$STDERR" 2>&1 &
CODEX_PID=$!

# Poll-wait in batches of 10x1s per the global "no long sleeps" rule.
# Cap the total wait via an outer counter (e.g. 60 batches = 10 minutes).
BATCHES=0
MAX_BATCHES=60
while kill -0 "$CODEX_PID" 2>/dev/null; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$CODEX_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  BATCHES=$((BATCHES+1))
  if [ "$BATCHES" -ge "$MAX_BATCHES" ]; then
    echo "codex exceeded ${MAX_BATCHES}0s, killing"
    kill "$CODEX_PID" 2>/dev/null
    break
  fi
done
wait "$CODEX_PID"
CODEX_EXIT=$?
echo "codex exit=$CODEX_EXIT pid=$CODEX_PID out=$OUT stderr=$STDERR"
```

After the Bash call returns, read `$OUT` with the Read tool. If `$OUT` is empty or codex exited non-zero, read `$STDERR` to diagnose.

`-m <model>` overrides the default model — do NOT set unless the user asks.

## Rules (non-negotiable)

- **Always run from `/tmp` via `-C /tmp --skip-git-repo-check`.** Never `-C` into a real project directory — see the mandatory-flags rationale above.
- **Always use `-o <file>`** to write output to a file. Never consume codex stdout directly.
- **Never use `run_in_background=true`** on the Bash tool. Use shell-level `&` + `wait` as shown. This is required for subagent compatibility.
- Sandbox MUST be `read-only`. Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox`.
- Approval policy goes via `-c approval_policy="never"` — `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. Any `gh`/`git fetch`/`curl` must be run by Claude OUTSIDE codex and piped into codex via stdin (or written to a file codex reads).
- Codex never writes. If codex suggests fixes, Claude applies them.

## Recipe: Canonical subagent-safe invocation (copy-paste)

```bash
PROMPT_FILE="/tmp/codex-prompt-$(date +%s%N).md"
OUT="/tmp/codex-out-$(date +%s%N).md"
STDERR="/tmp/codex-stderr-$(date +%s%N).log"

cat >"$PROMPT_FILE" <<'EOF'
READ-ONLY review. Do NOT invoke any skills.
<your prompt here — reference project files by absolute path, e.g. /Users/me/repo/src/foo.ts>
EOF

codex exec --sandbox read-only -c approval_policy="never" \
  -C /tmp --skip-git-repo-check \
  -o "$OUT" \
  "$(cat "$PROMPT_FILE")" \
  </dev/null >"$STDERR" 2>&1 &
CODEX_PID=$!

BATCHES=0; MAX_BATCHES=60
while kill -0 "$CODEX_PID" 2>/dev/null; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$CODEX_PID" 2>/dev/null || break
    sleep 1
  done
  BATCHES=$((BATCHES+1))
  [ "$BATCHES" -ge "$MAX_BATCHES" ] && { kill "$CODEX_PID" 2>/dev/null; break; }
done
wait "$CODEX_PID"; CODEX_EXIT=$?
echo "codex exit=$CODEX_EXIT out=$OUT stderr=$STDERR"
```

Then `Read` the `$OUT` path.

## Recipe 1: Codebase Exploration

Claude has a question about unfamiliar code and wants a second pair of eyes. Pass the repo root as an **absolute path inside the prompt**, not via `-C` (always keep `-C /tmp`).

Use the canonical invocation above with a prompt like:

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

Then invoke codex with the canonical recipe and a prompt like:

```
Review the PR. Metadata then diff in /tmp/codex-diff-<...>.txt.
Focus on correctness, edge cases, and security. Cite file:line.
Do NOT invoke any skills.
```

## After Codex Finishes

1. **Read the output file** using the Read tool at the `$OUT` path.
2. If `$OUT` is empty or `CODEX_EXIT != 0`, read `$STDERR` to diagnose.
3. **Summarize** codex's findings back to the user.
4. **Apply any fixes** Claude agrees with — codex itself made no changes.
