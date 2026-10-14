---
name: "create-verification-skill"
description: "Generate a repo-local `verify` skill that drives the app the way a user does (any language, framework or platform), plus a STAGING mode: `.claude/verify.json` with a deployed-SHA check and read-only probes that the post-merge watcher runs. Use for /create-verification-skill, when a repo has no `.claude/skills/verify/`, or when a repo has no scripted way to prove UI, CLI or service behavior on staging."
argument-hint: "[repo path]"
---

# Create a verification skill

Every repo that ships needs a scripted way to drive the real app and prove behavior: launch it, exercise a feature the way a user would, and capture evidence, locally and on staging. This skill generates that as `<repo>/.claude/skills/verify/` plus `<repo>/.claude/verify.json`. Write for the next agent, not for a human: it reads the skill cold, mid-task, with no memory of the app.

## 1. Interview the repo, not the user

Answer these from the codebase. Ask the user only what you cannot observe, and only in a human-only category.

- **Surface:** what does a user touch? A web UI, a CLI/TUI, a desktop app, an API, a mobile app, a library? A repo can have several. Pick the primary one and note the rest.
- **Run:** how does the app start locally? Prefer the repo's own documented dev command (package scripts, Makefile, README quickstart). Note ports, env vars, seed data and auth.
- **Drive:** how can an agent interact with it programmatically? Existing harnesses first: Playwright specs, expect scripts, PTY helpers, curl-able endpoints, a debug port, the repo's device or simulator skill. Then a generic recipe: Chrome MCP for web, a tmux/PTY harness for CLI/TUI, plain HTTP for services.
- **Observe:** what evidence can be captured? Screenshots, terminal transcripts, response bodies, logs, exit codes, DB state.
- **Isolate:** can two instances run side by side (ports, data dirs, profiles)? If not, say so in the generated skill. Refusing to double-drive a shared instance beats corrupting the user's session.
- **Deploy:** where does a merge to the default branch go? Read `.github/workflows`, Pulumi stacks, `vercel.json`, `railway.json`, Dockerfiles and deploy scripts. List each staging target, its URL, and how long a deploy takes.

If the checkout does not build or start as-is, fix that first (or end with `STATUS: FAILURE` and the exact error) before generating. A skill written against a broken base teaches wrong steps. When an irrelevant missing asset blocks startup (a static dir the API never serves, a sample config), the generated skill may create it, marked as verification scaffolding, and remove it in cleanup.

## 2. Generate the skill

Write `<repo>/.claude/skills/verify/SKILL.md` with frontmatter (`name: verify` and a `description` that names the app, the surface, and when to use it; without frontmatter the skill never registers) and these sections, each grounded in what the interview found (no placeholders left):

- **Launch:** the exact command that starts the app for verification, and how to tell it is ready (a log line, a prompt). Launch must reach a usable state from an empty data dir, including migrations and seed data. Ready means usable, not just that a process answers. A database health check can pass while its init scripts still run. Include teardown. For a short-lived CLI or TUI there is no server: launch means build once, then start each drive in its own isolated PTY or tmux session.
- **Doctor:** one read-only check that answers "is this instance worth driving?": process up, right version or build, port owned by us, auth valid. Run it first whenever anything looks off.
- **Drive:** the harness recipe with real selectors and commands from this repo, not examples. Prefer stable handles (ARIA labels, data attributes, prompt strings, route paths) over coordinates and tab order.
- **Evidence:** what to capture and where it goes. Proof standards: exercise the real user path, not internal setters or test-only endpoints. Capture the action and the resulting state, not just the final screen. Verify side effects (files written, rows inserted, messages sent) alongside what is visible. Use mocks only where a production boundary already isolates the external system. When the safe path is a dry run or test mode, observe what it really skips (files, network, git refs) rather than trust its name.
- **Cleanup:** how to tear down what the run created. Never kill by process name; kill what you started. Cleanup removes scratch state, never the evidence. Proof artifacts survive teardown in the evidence directory the skill names.
- **Helpers:** every script the skill ships is executable, and its invocation is shown in the skill body. A helper the reader has to reverse-engineer is not a helper.
- **STAGING mode:** the section described in step 4.

## 3. Seed the feature map

Create `<repo>/.claude/skills/verify/features/README.md` plus one file per user-facing feature you can identify (start with the top 3 to 5, from routes, commands, menus or docs). Follow [`references/feature-map-example/`](references/feature-map-example/): a README index and one file per feature. Each file answers, from the user's point of view: what the feature is, how to reach it, how to drive it with the harness, and what observable end state proves it works. The four H2s are `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, and `Gotchas`. Mark features with a visible UI as `ui: true` in the README index.

If the seed data lacks a precondition that a journey needs, the journey reports a failure and the reason goes in that feature's `Gotchas`. Never weaken the journey to make it pass. The map is the repo's maintained verification source. A proof that drives one convenient entry point is incomplete when the map lists others.

## 4. STAGING mode

The STAGING section of the generated skill proves a merge on the deployed target, not on localhost.

### 4.1 Deployed-SHA match

- Find an endpoint or artifact that exposes the commit SHA of the running deploy (the full SHA, or at least its first 7 characters): a `/healthz` or `/version` field, a build-info file, or a response header.
- If none exists, add one in the same PR (for example, a `/version` route that returns the build's `GIT_SHA`, injected at build time).
- If the target cannot expose its SHA, the target is not verifiable. End with `STATUS: FAILURE no-deployed-sha: <target> <what you tried>`. Do not skip it silently.

### 4.2 `.claude/verify.json`

Write the config at the repo root's `.claude/verify.json`:

```json
{"targets":[{"name":"staging","sha_url":"https://staging.example/version","sha_jq":".sha","timeout_s":1800,"probes":[{"cmd":"curl -fsS --max-time 10 https://staging.example/api/ping","expect":"ok"}],"ui":false}]}
```

- `sha_url` and `sha_jq`: where the deployed SHA lives, and the `jq` filter that extracts it. The observed value must be the merge SHA or a prefix of it with at least 7 characters.
- `timeout_s`: how long a deploy may take. Default 1800. Use a longer value for mobile and store paths.
- `probes`: read-only smoke commands, cheap enough to run on every merge. A probe passes when it exits 0 within 120 s and its output contains `expect` (when set). A probe never writes data.
- `ui`: true when the target has user-visible screens that need UI proof.
- A repo with no deploy writes `{"targets":[],"reason":"<why>"}`. That records n/a with a reason, not a skip.
- The post-merge watcher reads this file from the merge commit's first parent (the base branch), so a new or changed config applies from the next merge on. Merge the config PR first.

### 4.3 The STAGING run

The generated STAGING section tells the agent to run these steps, in a subagent that did not write the change:

1. Run the shared staging check. It is the same script the post-merge watcher runs, so the evidence is the record the Stop gate reads:
   ```bash
   bash ~/.claude/scripts/staging_verify.sh <owner/repo> <pr> <pr> <merge_sha> none
   ```
   It reads `.claude/verify.json` from the merge commit's first parent, polls each target's `sha_url` until it serves the merge SHA or `timeout_s` passes, runs the probes, prints one verdict line (`Staging verify PASSED|N/A|NOT CONFIGURED|FAILED ...`), and appends a `verify` record to the session ledger: `repo`, `pr`, `merge_sha`, `result` (`pass`, `n/a`, `no-config`, `fail` or `error`), `reason`, `config_sha`, and `targets[]` with `name`, `observed_sha` and `probes[]` (`cmd`, `exit`, `matched`, `out_head`, `out_sha256`). `bash ~/.claude/scripts/done_gate.sh status` prints the ledger. Save the verdict line to `$EVIDENCE/verdict.txt`.
2. Drive the changed feature on staging with the feature map's recipe.
3. For `ui: true` targets, drive the UI with Chrome MCP or the repo's device skill. Capture screenshots (before and after where possible) and a GIF when there is motion. Upload them to the Linear ticket (`mcp__linear__prepare_attachment_upload`, `create_attachment_from_upload`, then `save_comment`) and to the PR (`add-images-to-pr` skill). Write the returned URLs, one per line, to `$EVIDENCE/ui_proof.txt`.
4. Report: the verdict line, each feature check (command or click path, observed result), and the evidence URLs.

`$EVIDENCE` is `~/.claude/verify-evidence/<owner>__<repo>/<merge_sha>/`. Create it with `mkdir -p`. Cleanup never deletes it.

## 5. Prove the generated skill before handing it over

Run its own instructions end to end once: launch, doctor, drive one mapped feature, capture evidence, clean up. After cleanup, confirm the evidence still exists at the named location. A cleanup that eats the proof fails this step. Then run the STAGING mode once against the current staging deploy, and paste the probe result and one UI proof URL. Until the config is merged, `staging_verify.sh` reports NOT CONFIGURED, so run the working-tree config by hand: fetch each `sha_url` with its `sha_jq` and compare it with the default-branch HEAD, then run each probe and check its exit code and `expect` text.

Fix what fails, and run the generated cleanup after every failed iteration, so broken attempts do not strand processes and ports. A generated skill that was never executed is a draft, not a deliverable. If you proved it in a stand-in for the real target (a container instead of a fresh VM, a local stack instead of staging), list every setup step the stand-in did that the target will not. Those steps stay unverified until a run on the real target covers them.

## 6. Ship it

Open one PR with `/pr-create` that adds `.claude/skills/verify/`, `.claude/verify.json`, and the deployed-SHA endpoint if you added one. Merge it on green CI per AGENTS.md. Point to `/maintain-verification-skill` for keeping the map honest as the app changes.
