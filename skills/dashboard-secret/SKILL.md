---
name: "dashboard-secret"
description: "Get a secret value that only exists in a third-party dashboard (Supabase, GCP, etc.) and seed it into keyshelf. Use whenever a fix needs a credential/API key/password that has no CLI or Management-API retrieval path — resetting a DB password, revealing a service-role/secret API key, copying an OAuth client secret, etc."
---

## Why this exists

Some credentials can only be obtained by clicking around a web dashboard —
there is no `gcloud`/`supabase`/API call that returns them. Never ask the
user to paste the raw secret into chat — it stays in the transcript.

The default is: the user clicks reveal/reset/copy themselves, in their own
browser session. That default exists mainly to stop the plaintext value from
ever landing in something that persists it where a later reader (human or
model) could see it — most concretely, a `computer` screenshot taken to
verify a browser click, which would capture live secret text as an image in
the tool-call history.

**Narrow exception — I (Claude, via Chrome MCP) may do the click myself**
when the user explicitly asks for it for a specific credential, AND the
leak vector above is actually avoided:

- Click the **copy-to-clipboard icon only**. Never click "reveal"/the eye
  toggle first — the copy icon grabs the real underlying value regardless of
  whether it's currently masked on screen, so there's no need to display it.
- Take **no screenshot** of that page between locating the copy control and
  clicking it, and none after. Use `find` (semantic element lookup, returns
  refs/descriptions, not rendered content) to locate the control instead of
  `computer screenshot`.
- If the copy icon can't be found/clicked without a reveal step in the way,
  stop and fall back to asking the user to click it themselves — don't
  reveal-then-screenshot to "verify" the click worked.
- A one-time-viewable secret (shown once, never again — e.g. a Theme Access
  token) is NOT eligible for this exception regardless of what's asked: a
  failed automated attempt there can't be retried, only rotated. Human-only,
  no exceptions.

## Process

1. Tell the user exactly which dashboard page has the field (e.g.
   "Settings > API > Secret keys > the `sb_secret_...` value, not the
   publishable key"). If resetting/rotating, warn that it invalidates the
   old value for every consumer first.
2. Either ask them to copy it with Cmd+C (not paste into chat) and confirm
   when done, or — only if they've asked you to do the click, and the
   exception above applies — do it yourself via Chrome MCP and confirm the
   copy succeeded structurally (e.g. a "Copied" toast/aria-live region via
   `find`/`read_page`), never by screenshotting the value.
3. Run it straight from the clipboard, never through a variable that could
   land in a transcript or shell history, and **only with cwd inside a
   worktree, never the base repo checkout** — `keyshelf set` writes the
   binding it creates back into the environment file it targets as a side
   effect, so running it in the base repo dirties `main` directly (confirmed
   live: this exact command, run at the repo root, left an uncommitted stray
   diff even though the same content had already landed via a worktree+PR).
   See this repo's own `keyshelf` skill's "mistakes to avoid" if one exists:
   ```bash
   pbpaste | pnpm exec keyshelf set --secret <KEY_NAME> <shelf>/<env>
   ```
4. Immediately clear the clipboard yourself: `pbcopy < /dev/null`.
5. If the change also needs a version bump / infra opt-in (e.g. a
   `sunsay:optionalSecrets` entry, a Pulumi redeploy), do that as a normal
   worktree + PR — the keyshelf `set` only writes the Secret Manager version,
   it doesn't wire consumers up to read it.
