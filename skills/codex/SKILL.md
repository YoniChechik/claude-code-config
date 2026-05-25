---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

## Invocation Template (use verbatim)

Every codex invocation MUST write output to a temp file via `-o`. Run the command using `run_in_background=true` on the Bash tool -- Claude gets auto-notified when the process finishes.

```bash
CODEX_OUT="/tmp/codex-out-$(date +%s%N).md"

codex exec \
  --sandbox read-only \
  -c approval_policy="never" \
  -C "<repo-or-dir>" \
  --skip-git-repo-check \
  -o "$CODEX_OUT" \
  "<review prompt>"
```

Run the above with `run_in_background=true`. When notified of completion, read `$CODEX_OUT` with the Read tool.

`-m <model>` overrides the default model -- do NOT set unless the user asks.

## Rules (non-negotiable)

- **Always use `-o <file>`** to write output to a file. Never consume codex stdout directly.
- **Always use `run_in_background=true`** on the Bash tool call. Never run codex in the foreground.
- Sandbox MUST be `read-only`. Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox`.
- Approval policy goes via `-c approval_policy="never"` -- `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. Any `gh`/`git fetch`/`curl` must be run by Claude OUTSIDE codex and piped into codex via stdin (or written to a file codex reads).
- `--skip-git-repo-check` is required when `-C` points at a non-git dir (e.g., a standalone plan.md).
- Codex never writes. If codex suggests fixes, Claude applies them.

## Recipe 1: Codebase Exploration

Claude has a question about unfamiliar code and wants a second pair of eyes.

```bash
CODEX_OUT="/tmp/codex-out-$(date +%s%N).md"

codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
  -o "$CODEX_OUT" \
  "Explore this repo and explain <question>. List the key files involved."
```

Run with `run_in_background=true`. Then read `$CODEX_OUT` with the Read tool.

## Recipe 2: Plan / Design .md Review

Have codex stress-test a design doc for missing considerations.

```bash
CODEX_OUT="/tmp/codex-out-$(date +%s%N).md"

codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" --skip-git-repo-check \
  -o "$CODEX_OUT" \
  "Review the plan at <path/to/plan.md>. Flag missing considerations, risks, or unclear steps."
```

Run with `run_in_background=true`. Then read `$CODEX_OUT` with the Read tool.

## Recipe 3: PR Diff Review

Codex cannot reach GitHub. Claude fetches the diff first, writes it to a temp file, then codex reads it.

```bash
# Pre-fetch the diff outside codex (codex has no network)
DIFF_FILE="/tmp/codex-diff-$(date +%s%N).txt"
gh pr diff <NUM> > "$DIFF_FILE"
```

Then run codex in a separate Bash call with `run_in_background=true`:

```bash
CODEX_OUT="/tmp/codex-out-$(date +%s%N).md"

codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
  -o "$CODEX_OUT" \
  "Review the PR diff at $DIFF_FILE. Focus on correctness, edge cases, and security. Cite file:line."
```

For richer context, concatenate metadata and diff into one file:

```bash
DIFF_FILE="/tmp/codex-diff-$(date +%s%N).txt"
{ gh pr view <NUM> --json title,body,files; echo '---DIFF---'; gh pr diff <NUM>; } > "$DIFF_FILE"
```

Then run codex in a separate Bash call with `run_in_background=true`:

```bash
CODEX_OUT="/tmp/codex-out-$(date +%s%N).md"

codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
  -o "$CODEX_OUT" \
  "Review this PR. Metadata then diff in $DIFF_FILE. Cite file:line."
```

Then read `$CODEX_OUT` with the Read tool.

## After Codex Finishes

1. **Read the output file** using the Read tool at the `$CODEX_OUT` path.
2. **Summarize** codex's findings back to the user.
3. **Apply any fixes** Claude agrees with -- codex itself made no changes.
