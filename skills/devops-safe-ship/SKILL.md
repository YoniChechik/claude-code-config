---
name: "devops-safe-ship"
description: "DevOps playbook for risky multi-step rollouts, migrations, and cutovers — incremental single-purpose PRs, inert-but-present fallbacks for one-line rollback, self-validation in prod (Chrome walkthroughs, /healthz probes, expected-vs-observed GO/NO-GO tables, negative controls), human-gated irreversible steps, CI-guard discipline, and durable milestone memory. Invoke for any high-blast-radius change e.g. auth/issuer cutovers, signing-key revokes."
argument-hint: "[what you're rolling out]"
---

# Safe-Ship: Risky Rollout Playbook

A repeatable procedure for shipping high-blast-radius changes (auth cutovers, key
revokes, etc.) without breaking prod and without a human
babysitting every step. **You prepare, verify, and present; the human pulls the
trigger on anything irreversible.** Land one risky thing at a time, prove it with
real signals, and keep a one-line rollback ready before you merge.

## When to use

Invoke for: issuer/auth cutovers, signing-key revokes, hard-to-reverse changes,
or any change where a mistake locks users out or can't be
trivially undone. For ordinary additive features use `/new-feature` or `/plan`.

## Rollout under design: "$ARGUMENTS"

## The seven disciplines

### 1. Incremental delivery — one risky change per PR
- **One PR = one purpose.** Split the rollout into the minimum ordered PRs the
  deploy-ordering forces (e.g. auth foundation → relocation → enablement →
  cutover → cleanup). Never bundle unrelated risk into one PR.
- **Land + verify before the next step.** Each PR must be CI-green and its effect
  confirmed in prod (or proven no-op) before you build the one after it.
- **Consolidate follow-ups, never risk.** Housekeeping and small fixes can share a
  cleanup PR; a lockout-capable flip gets its own PR.
- Prefer **additive first**: introduce the new shape, run both in parallel, cut
  over, then retire the old shape in a later PR.

### 2. Fallback / rollback readiness — keep the old path inert-but-present
- **Make rollback one line.** When you flip to a new path, leave the old path in
  the code but disabled — e.g. empty a `frozenset()`/allowlist to disarm dual-accept
  rather than deleting the fallback branch. Restoring the set is the rollback; you
  delete the dead code in a *separate later* cleanup PR.
- **Targeted rollback over destroy.** Prefer the fastest reversible path (Cloud
  Run revision rollback in seconds; git-revert of an env remap) over anything that
  destroys state.
- **Document rollback in the PR body BEFORE merging** — the exact command/steps,
  primary fast path and durable path. If you can't write the rollback, you're not
  ready to merge.
- Order matters: don't remove a fallback until a **verification kit** has
  proven the new path in prod. A rollback-order guard (fails a revert done in the
  wrong sequence) is worth adding for the window it's live.

### 3. Self-validation over blind trust — prove it in prod with real signals
Never declare success from "the deploy went green." Gather real evidence:
- **Health probes.** Add/hit a public `/healthz/...` endpoint that reports the
  actual live state (issuers configured, jwks reachable, key counts, gate lists).
  Compare live output to the expected shape.
- **Real-token walkthrough.** Drive a Chrome MCP session as a real user, capture a
  real session token, decode it (assert `alg`/`iss`/`aud` are what you expect
  *before* using it), then sweep every affected route.
- **Expected-vs-observed table = the GO/NO-GO gate.** Build a route/step table with
  an expected status per row; run the sweep; any deviation from expected is a
  NO-GO until explained. Known-accepted deviations must be pre-listed with a reason.
- **Negative controls.** A garbage/expired token MUST 401 everywhere — prove the
  gate actually rejects, not just that the happy path 200s.
- **Verification kits replace "soak."** A concrete kit (route table, sweep script,
  checklist, browser plan) that a human/agent runs and reads as GO/NO-GO is
  stronger and faster than an open-ended time-based soak. Keep it in scratchpad.

### 4. Manual-gated prod steps — human times the irreversible ones
Hard-to-reverse actions are **human-timed and human-approved**. You do everything
up to the trigger; the human pulls it (business hours, pre-announced, aware).
- Gated actions: prod deploy of a cutover, signing-key **revoke**, admin/force
  merge, company-wide re-login flips, `pulumi stack init`, destructive migration,
  hard-delete of prod rows.
- **Pre-checks ABORT on uncertainty — never proceed.** Never revoke a key unless
  you've confirmed the replacement is the sole active signer. Never hard-delete
  without a final concrete-list confirmation. Prefer a **reversible fallback**
  (ban vs hard-delete) when the destructive path hits a constraint.
- **Catch the blocker with a canary before the flip.** A production-shaped canary
  (real login on a build pointed at the new path) is what surfaces the real
  blocker — e.g. a JWKS that publishes an ES256 key but still *signs* with the
  legacy HS256 secret would 401 every real token at cutover. Find it here, not in
  prod at 2am.
- **Build to green, then PAUSE.** For the cutover PR: get it CI-green and fully
  ready, write the attestation/rollback in the body, then stop and hand the merge
  to the human.

### 5. Guards & CI discipline
- **Expect required guards** and understand *how* they run. Base-ref/anti-tamper
  guards execute the **`origin/main` copy** of their matcher against the PR diff —
  so a fix *to a guard script* is INERT in its own PR and must land on main FIRST
  (via a prior PR, possibly force-merged for a benign self-trip).
- **Distinguish benign-by-design RED from a real failure.**
  - *Benign RED* (force-merge OK): a guard that fires **by design** on the very PR
    it's meant to catch (e.g. `bo-repoint-guard` red-flagging the sanctioned
    repoint), or a guard tripped by literal strings in its own tooling/bats. Merge
    past it via admin force-merge — but **print WHY it's benign** and rely on the
    *other* (green) preflight as the real safety.
  - *Real failure*: fix first, never force-merge.
- **Preflight green is the real gate.** When you force-merge past a by-design RED
  guard, a separate automated preflight must be genuinely GREEN — that's the safety,
  not the human's judgment alone.
- **Retire guards when their job is permanently done** (delete the workflow; if
  required-checks are auto-derived from workflow files, deletion de-registers the
  context atomically — no orphan).
- Treat infra flakes (preview-branch provisioning timeouts, GRANT races) as
  **re-run**, not fix.

### 6. Orchestration mechanics
- **Throwaway clones off FRESH `origin/main`.** `git fetch` first, branch the clone
  off up-to-date origin/main — never the stale local main, never the base repo dir.
- **Background subagents + poll-loops.** Wait via a 1s-sleep for-loop, ≤10s per
  iteration (target ~3s avg); never a single long `sleep`, never
  `run_in_background=true` on Bash *inside a subagent* (use shell `&` + `wait`).
- **Persistent CI watcher** per feature branch (`/ci-watcher`) — never auto-kill it;
  keep fixing/re-syncing on every "behind" alert.
- **Dodge hook false-positives.** Write commit messages and PR bodies to a file and
  pass `--body-file`/`-F` — the base-dir hook false-positives on git-words inside
  `$(...)` / prose.
- **Second opinion before merge.** Run a `/codex` read-only review on the plan and
  on the diff of any risky PR before merging.

### 7. Memory, continuity & communication
- **Persist milestone state to durable memory after each significant step** so work
  survives compaction: which PRs merged (numbers + commits), what's verified in
  prod, what's the next human-gated action, and every rollback path. Update it, keep
  it accurate, mark the roadmap HISTORICAL once done.
- **Keep a live task list** — add all steps on invocation, remove each as completed.
- **Communicate crisply.** Status tables, not prose walls. Surface the ONE decision
  that needs the human, recommend a default, don't over-ask. Flag known-accepted
  regressions explicitly rather than hiding them.

## Procedure when invoked

1. **Map the rollout** into the minimum ordered PRs deploy-ordering forces. Note for
   each: additive vs risky, auto-deploy vs manual, rollback path. Add to task list.
   Run `/codex` on the plan.
2. **For each PR, in order:**
   a. Branch a fresh clone off `origin/main` (fetch first). Never the base repo.
   b. Implement the smallest coherent step. Keep the prior path inert-but-present if
      this is a flip.
   c. Write rollback + (for cutovers) an attestation block into the PR body via
      `-F`/`--body-file`.
   d. `/post` + `/codex` diff review; get CI green; launch `/ci-watcher`.
   e. Classify any RED guard: benign-by-design (force-merge, print why, lean on the
      green preflight) vs real (fix).
   f. **If the merge/deploy is irreversible → PAUSE and hand to the human** (pre-checks
      must pass or ABORT). Otherwise merge.
   g. **Verify in prod**: `/healthz`, real-token Chrome sweep, expected-vs-observed
      table, negative control. Deviation = NO-GO until explained.
   h. **Persist milestone to memory.** Move to next PR.
3. **After the point-of-no-return**, retire the fallback (separate cleanup PR),
   retire dead guards, and only then revoke/delete legacy artifacts — each with its
   own pre-check that ABORTS on uncertainty.
