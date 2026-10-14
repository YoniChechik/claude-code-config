---
name: "maintain-verification-skill"
description: "Keep a repo's `verify` skill, feature map and staging config (`~/.claude/verify/<owner>__<repo>.json`) honest: parallel source readers per feature, one live pass over every feature (local and STAGING), at most one PR of proven corrections. Use for /maintain-verification-skill, \"audit the verify skill\", or after a feature changes a user path."
argument-hint: "[repo path]"
---

# Maintain a verification skill

A feature map rots the moment the app changes. This skill is the upkeep loop for a skill made by `/create-verification-skill` (or any repo-local verification skill with a feature map). Run it after a feature changes a user path. The unit of rigor is the feature, not every sentence: cover every feature file from source and exercise every feature live.

## Outcomes

Pick one, and say which:

- **clean**: every feature got source and live coverage, and nothing needs a change. No branch, no PR.
- **changed**: one PR ships proven doc, harness or map corrections, and staging config corrections ship as one PR in `~/.claude`.
- **blocked**: coverage could not finish, or a proven fix could not ship safely. End with `STATUS: FAILURE verify-skill: <what blocked it>`.

## Edit scope

Edit only `.claude/skills/verify/` (its SKILL.md, `features/`, and harness scripts it owns) and `~/.claude/verify/<owner>__<repo>.json`. Never edit product code during a run. A behavior the map describes that the app no longer has is either doc drift (fix the map) or a product regression (report it, and do not paper over it in docs).

## Pass

0. **Locate the target.** Find `<repo>/.claude/skills/verify/`. If there is none, run `/create-verification-skill` instead of inventing a target.

1. **Index hygiene.** Read the feature map README and glob its sibling files. Fix missing, extra, duplicate or dead entries.

2. **Source wave.** One read-only subagent per feature file, launched in parallel. Each explains "how does this user-facing feature work?" from source, flags likely doc drift with `file:line` citations, and returns one live-verification recipe. These subagents never drive the app and never edit files. Return shape: feature summary, source entry points, likely drift or none, one recipe.

3. **Reconcile.** Every feature file has a returned summary. Merge overlapping recipes into as few app states as practical. Spot-check cited drift; do not re-prove clean claims. Sweep recent churn (`git log` since the map's last change) for user-facing surfaces missing from the map. Require a concrete source path before you call one missing.

4. **Live pass.** Required even when source looks clean. One subagent that did not write the recent changes owns all driving, and follows the verify skill's own launch model. Exercise every feature at least once, and hold three invariants the whole pass:
   - Never drive an instance you have not health-checked since it last did something surprising. Run doctor before the first drive, on each fresh session, and after any failed drive. Where doctor cannot see the failure (a wedged UI on a healthy process), reset to a known state or relaunch.
   - Evidence captured so far survives every cleanup. Check it at its named location; do not assume it.
   - Nothing a drive started outlives its use. Clean failed-iteration residue whether the session is stuck, exited or shared (for a shared instance, clean the residue, not the instance).

   A doctor failure caused by skill drift is drift: fix it under edit scope and retry once before you call the pass blocked. A feature that cannot be reached is `verified-unreachable` only with the concrete prerequisite (auth, entitlement, OS, external state) and the route attempted. If the map omits that prerequisite, that is drift. Re-drive every harness fix live before it ships. Final teardown happens after the last drive, so nothing outlives the run (evidence stays).

5. **STAGING pass.** Run the verify skill's STAGING mode once against the most recent merged PR (`gh pr list --state merged --limit 1`), which runs `~/.claude/scripts/staging_verify.sh`. Check that `~/.claude/verify/<owner>__<repo>.json` still matches reality: the `sha_url` returns the deployed SHA, every probe (an HTTPS GET with `expect_status` and `expect`) passes, `timeout_s` covers the observed deploy time, and new user-facing routes have a probe when one is cheap. For `ui: true` targets, capture one UI proof URL. A stale target or probe is drift: fix it in this PR.

6. **Triage.** Wrong or missing user-POV description: doc drift, fix it. Working behavior the harness cannot drive: harness gap, fix it (scripts executable, invocation in the skill body). App behavior that is broken: product gap. Report it with evidence, keep it out of this PR, and fix it in its own PR per AGENTS.md.

7. **Ship or stop.** For changed: one PR of proven corrections via `/pr-create`, after you re-read every changed file. Merge on green CI. For clean or blocked: no PR. Report the outcome and the coverage.

Keep run notes (features covered, unreachable prerequisites, confirmed drift, outcome) in the scratchpad. Do not commit them.
