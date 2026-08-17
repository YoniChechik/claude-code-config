---
name: "adhd-plan"
description: "ADHD-friendly planning mode: one short high-level summary, then a plain list of block names, then discuss each block one at a time on request"
argument-hint: "[topic]"
---

# ADHD Plan Mode

Plan big, multi-part things (architecture decisions, migrations, multi-block
initiatives) without dumping one huge message. Short pieces, one at a time,
user controls the pace.

## When to use

- Invoked explicitly (`/adhd-plan`), or
- The user asks for "ADHD-friendly" / "one at a time" / "step by step" planning, or
- Claude is about to plan something big enough that it would otherwise become
  one long message with many sections.

## Core interaction pattern

1. **High-level summary first.** One short paragraph: what we're doing and
   why, plain language, no details yet.
2. **List the blocks as names only.** A numbered list of short one-line names
   for the steps/decisions/open questions. No explanations yet.
3. **Stop.** Wait for the user to say "go" (or "next" / "continue").
4. **On "go," cover exactly one block.** Short, simple sentences. No jargon
   (or if a term is unavoidable, add a one-line plain-language explanation
   right after it). No long paragraphs. No tables. One idea per line/bullet.
   End with: "Say 'go' for the next one."
5. **Anything other than "go" means stay here.** A question, pushback, a
   change, a decision, "explain more" — all of that means: discuss this same
   block. Answer it directly. Do not advance until the user explicitly says
   "go" or is clearly done with this block.
   - **Exception — resolving answers auto-advance.** If the block ended with a
     question to the user, and the reply directly resolves that exact
     question (a decision, a closing clarification, an accepted correction)
     without raising a new question or asking for more discussion, treat it
     as an implicit "go" and move to the next block. If the reply itself asks
     something new, requests more discussion, or is ambiguous, stay and keep
     discussing — explicit "go" is always still valid too.
6. **Repeat step 4-5** until every block has been covered.

## New items that surface mid-conversation

If research, a second opinion, or the user raises something new adds an open
question or a new block partway through:

- Do not dump it immediately.
- Queue it and present it later using the exact same pattern: name it in one
  line, wait for "go" or discussion, one at a time.
- If it changes a block already covered, surface it as a new short item, not
  a rewrite of everything already said.

## Background research without blocking the conversation

When a block would benefit from real research (web search for best
practices, checking this repo's own documented conventions, a second-opinion
pass), do not block the step-by-step conversation on it:

- Dispatch it as a background subagent.
- Keep going with the user's current block while it runs.
- When it reports back, fold in only what's genuinely new, as a new queued
  item (see above) — never re-dump everything already covered.

## Formatting rules (always)

- Never use tables.
- Never write long paragraphs.
- Prefer short bullets or short numbered lines.
- Avoid jargon where a plain phrase works; when a technical term is
  unavoidable, follow it with a one-line plain-language explanation.

## End state: turn the approved plan into tracked work

Once every block and every open question has been explicitly resolved with
the user:

- If this is a coding project with a Linear workspace, turn the plan into
  tracked work: one parent/epic issue, with each block/decision as a nested
  sub-issue.
- Before creating anything, check a couple of existing issues in that
  workspace for the real ticket conventions and hierarchy — do not assume a
  format.
- Delegate this creation step to a subagent with the right tools (e.g. the
  `linear-ticket` skill/Linear MCP tools) rather than doing it inline — it has
  external side effects.
