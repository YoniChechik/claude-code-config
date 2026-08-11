---
name: "dashboard-secret"
description: "Get a secret value that only exists in a third-party dashboard (Supabase, GCP, etc.) and seed it into keyshelf. Use whenever a fix needs a credential/API key/password that has no CLI or Management-API retrieval path — resetting a DB password, revealing a service-role/secret API key, copying an OAuth client secret, etc."
---

## Why this exists

Some credentials can only be obtained by clicking around a web dashboard —
there is no `gcloud`/`supabase`/API call that returns them. Never navigate
there and click reveal/reset/copy yourself: that's a credential-security
action reserved for the user. Also never ask the user to paste the raw
secret into chat — it stays in the transcript.

## Process

1. Tell the user exactly which dashboard page to open and which field to
   copy (e.g. "Settings > API > Secret keys > reveal the `sb_secret_...`
   value, not the publishable key"). If resetting/rotating, warn that it
   invalidates the old value for every consumer first.
2. Ask them to copy it with Cmd+C (not paste into chat) and confirm when done.
3. Run it straight from the clipboard, never through a variable that could
   land in a transcript or shell history:
   ```bash
   pbpaste | pnpm exec keyshelf set --secret <KEY_NAME> <shelf>/<env>
   ```
4. Immediately clear the clipboard yourself: `pbcopy < /dev/null`.
5. If the change also needs a version bump / infra opt-in (e.g. a
   `sunsay:optionalSecrets` entry, a Pulumi redeploy), do that as a normal
   worktree + PR — the keyshelf `set` only writes the Secret Manager version,
   it doesn't wire consumers up to read it.
