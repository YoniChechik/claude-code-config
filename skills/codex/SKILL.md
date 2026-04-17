---
name: "codex"
description: "Use when Claude wants a read-only second opinion from OpenAI Codex CLI on: exploring an unfamiliar codebase, reviewing a plan/design .md, or reviewing a PR diff. Codex runs sandboxed read-only (no writes, no prompts, no network)."
argument-hint: "[target or question]"
---

# Codex: Read-Only Second Opinion via OpenAI Codex CLI

Delegate read-only review work to the `codex` CLI. Codex gets its own look at the code/plan/diff and reports back. Claude stays in charge of any writes.

## Invocation Template (use verbatim)

```bash
codex exec \
  --sandbox read-only \
  -c approval_policy="never" \
  -C "<repo-or-dir>" \
  --skip-git-repo-check \
  "<review prompt>"
```

Optional: `-o <file>` writes the final message to a file. `-m <model>` overrides the default model — do NOT set unless the user asks.

## Rules (non-negotiable)

- Sandbox MUST be `read-only`. Never use `--full-auto` (implies workspace-write) or `--dangerously-bypass-approvals-and-sandbox`.
- Approval policy goes via `-c approval_policy="never"` — `codex exec` has no `--ask-for-approval` flag.
- `read-only` sandbox **blocks network egress**. Any `gh`/`git fetch`/`curl` must be run by Claude OUTSIDE codex and piped into codex via stdin (or written to a file codex reads).
- `--skip-git-repo-check` is required when `-C` points at a non-git dir (e.g., a standalone plan.md).
- Codex never writes. If codex suggests fixes, Claude applies them.

## Recipe 1: Codebase Exploration

Claude has a question about unfamiliar code and wants a second pair of eyes.

```bash
codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
  "Explore this repo and explain <question>. List the key files involved."
```

## Recipe 2: Plan / Design .md Review

Have codex stress-test a design doc for missing considerations.

```bash
codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" --skip-git-repo-check \
  "Review the plan at <path/to/plan.md>. Flag missing considerations, risks, or unclear steps."
```

## Recipe 3: PR Diff Review

Codex cannot reach GitHub. Claude fetches the diff, pipes it in.

```bash
gh pr diff <NUM> | codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
  "Review this PR diff. Focus on correctness, edge cases, and security. Cite file:line."
```

For richer context, concatenate and pipe:

```bash
{ gh pr view <NUM> --json title,body,files; echo '---DIFF---'; gh pr diff <NUM>; } \
  | codex exec --sandbox read-only -c approval_policy="never" -C "$PWD" \
    "Review this PR. Metadata then diff below. Cite file:line."
```

## After Codex Responds

- Summarize codex's findings back to the user.
- Apply any fixes Claude agrees with — codex itself made no changes.
- If codex output is long, re-run with `-o codex-out.md` and read the file.
