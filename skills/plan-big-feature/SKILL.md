---
name: "plan-big-feature"
description: "Decompose a large, multi-part feature or initiative into decoupled groups (epics), research each with parallel subagents (get a second opinion from Codex on genuinely hard architecture calls), draft MVP-scoped tickets under each group — created in the project's ticket tracker if one exists, else a single markdown plan file as fallback — and gate ALL implementation behind a full `/one-by-one` user-approval pass. Never let implementation start before that gate completes."
argument-hint: "[feature or initiative description]"
---

# Plan Big Feature

For an initiative too big and too tangled for a single `/plan` (which is scoped to one feature, one PR). This skill produces the *decomposition* — the set of decoupled epics and their draft tickets — not an implementation plan for any one of them. Once a resulting sub-ticket is picked up for real work, it goes through `/plan` on its own.

The whole point of this skill is the hard gate at the end: a big initiative must not start getting built piecemeal just because someone had a good idea about part of it. Everything gets decomposed, proposed, and explicitly walked through with the user first.

## When to use this

The user describes something that is really several independent efforts wearing one name — a "mega issue," a platform migration, a feature with 4+ genuinely separable workstreams, a restructure of existing tracked work. If it fits in one PR or one epic without contortion, this skill is overkill — use `/plan` instead.

## Process

### Step 1: Research, in parallel

Fan out parallel subagents (never sequential — this is exactly the kind of work that benefits from it) across the distinct areas the initiative touches. Each research subagent should:
- Read the actual code/config/docs, not assume from memory — an initiative like this usually spans work done over many sessions, and stale assumptions (a file that got deleted, a store that got migrated, a feature that already shipped) are the single biggest way this kind of plan goes wrong.
- Come back with concrete findings: exact file paths, exact ticket IDs (if a tracker exists), exact tradeoffs — not vague summaries.

For any research question that's a genuinely hard, load-bearing architecture call (not a matter of just reading the code to find the answer) — get a second opinion from the `codex` CLI (`codex exec -s read-only --skip-git-repo-check -`, prompt piped via stdin; check `codex --help` for exact flags if unfamiliar). Give it the concrete facts your own research already found, not a blind question. Preserve its actual response (don't paraphrase away disagreement) in the final plan.

You (the orchestrator) synthesize the parallel findings yourself — never delegate the synthesis to another agent. Understanding what the research means, and what to propose because of it, is the one part of this process that must not be delegated.

### Step 2: Decompose into decoupled groups

Split the initiative into epics that are genuinely independent — each should be shippable/reviewable/droppable without the others falling over. For each group, work out:
- A clear scope boundary (what's in, what's explicitly out).
- Real dependencies between groups, stated explicitly (which group blocks which, and why) — don't let a group's ticket claim "blocked on X" if X isn't actually a group's own gating condition.
- A draft list of MVP-scoped sub-tickets (title + one-line scope each) — resist gold-plating; a group with 15 speculative tickets is worse than one with 5 that actually need deciding now.
- Which EXISTING tickets (if the project already tracks some of this work) should move under it, by exact ID.

Explicitly call out, as its own section, any additional group you think the user might be missing — don't just answer the groups they named.

### Step 3: Write the proposal

Prefer creating this directly as tracked tickets in whatever the project already uses (Linear, GitHub Issues, etc.) if that tracker exists and the codebase already has conventions for it (epic/sub-issue nesting, a standing team/project). If no tracker exists, or the project has no ticket-based workflow, fall back to a single markdown plan file (mirroring `/plan`'s own `plan-$FEATURE_NAME.md` convention: worktree root, TLDR, research/references, one section per group) as the sole source of truth instead.

Either way — **do not actually create, move, or edit anything yet.** This step produces the proposal only. State this explicitly to the user when you hand it over.

If a `/codex`-style critique skill exists in this environment, run it against the finished proposal (file or drafted ticket set) before presenting it, the same way `/plan` runs its own Codex critique pass — flag weak spots, missing considerations, bad sequencing between groups, unclear scope boundaries. Apply only surgical, uncontroversial fixes directly; anything Codex raises that changes scope goes to the user as an open question, not a silent edit.

### Step 4: The gate — one-by-one review, before anything is built

This is the non-negotiable part. Once the proposal exists, the very next action is: invoke `/one-by-one` over the full proposal — every group, then every ticket within each group the user wants to walk — and let the user accept, cut, or change each one. Follow `/one-by-one`'s own rules on this: log every decision, defer every action (including edits to unrelated things that come up mid-walkthrough) until the whole pass finishes, then apply everything only after explicit confirmation.

**Do not implement anything, and do not let the user start implementing anything from this initiative, until this full review pass has actually completed and been confirmed.** If the user tries to jump straight to building a piece of it mid-decomposition ("let's just start on X"), say so plainly and redirect back to finishing the review first — the entire reason this skill exists is to stop good ideas from turning into scattered, unreviewed work.

### Step 5: Apply

Only after Step 4's confirmation: create/move the real tickets (or finalize the markdown file), exactly as decided in the walkthrough — including any tickets that got reshaped, merged, split, or newly invented mid-review, not just the original Step 3 draft.

**Every group gets its own approval-gate ticket, always.** When creating a group's tickets in the tracker, add one more: "Approve [Group Name] scope (one-by-one review gate)," positioned as that group's first task and set to block every other sub-issue under it. This is what makes Step 4's rule durable after this skill's own conversation ends — someone opening this epic cold, weeks later, sees the gate ticket and knows implementation on anything else in it is blocked until that review happened. If the review for a given group already happened live in this same session (i.e. this group already went through Step 4), create its gate ticket already Done, with a comment recording that it was approved via the one-by-one walkthrough and roughly when — it's a completed gate, not an open blocker, but the relation still gets set on all its sibling tickets so the rule is visible on the record regardless. For a group not yet reviewed, the gate ticket stays open, genuinely blocking, until its own Step 4 pass completes.

## After this skill finishes

The output is decomposed, ticketed (or documented), and approved — not implemented. Picking up any single resulting ticket for real work is a separate, later action, and a big/non-trivial one should go through `/plan` on its own rather than being implemented ad hoc.
