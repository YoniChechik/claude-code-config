---
name: "gcloud-auth"
description: "Re-authenticate an expired gcloud session. Use PROACTIVELY, without being asked by name, whenever a `gcloud`/`gsutil`/`bq`/`pulumi` command fails on credentials — 'reauthentication required', 'invalid_grant', 'invalid_rapt', 'credentials not found', 'token has expired', 'Reauthentication failed', ADC/refresh-token errors, or a `pulumi` command (e.g. `pulumi whoami`, `pulumi login`, `pulumi up` against the GCS state backend) failing with `invalid_grant`/`invalid_rapt` — or whenever the user asks to re-auth, re-login, or log in to gcloud."
---

Re-auth is usually `gcloud auth login` — it opens Chrome automatically, the user
approves, and the credentials are valid for ~1 day. **But that alone is NOT
enough for anything that reads Application Default Credentials (ADC)** — most
notably Pulumi's GCS state backend (`gs://sunsay-pulumi-state` and siblings like
`gs://sunsay-app-pulumi-state`). ADC is a fully separate credential store from
the regular user login; `gcloud auth login` does not populate it. Missing ADC
does not fail with an obvious auth message — it surfaces as a confusing
`invalid_grant` / `invalid_rapt` error from `pulumi` commands, which gives no
hint that ADC is the missing piece.

## Process

### Step 1: Ping the user
Invoke the `/notify-waiting` skill FIRST. Step 2 blocks waiting for browser approval, so the user must be at their machine before it starts.

### Step 2: Decide which login(s) are needed
- Failing command was `gcloud`/`gsutil`/`bq`, and the error is a plain
  reauth/expired-token message with no `pulumi`/ADC signal → `gcloud auth login`
  only.
- Failing command was `pulumi` (or anything else reading ADC), OR the error text
  contains `invalid_grant` / `invalid_rapt` / mentions Application Default
  Credentials → run **both** logins below. `gcloud auth login` alone will NOT
  fix this.
- Unsure which applies? Run both — it's cheap and avoids a second round-trip.

### Step 3: Log in
Run directly via a **subagent Bash call**, one at a time (each opens its own Chrome tab):
```bash
gcloud auth login
gcloud auth application-default login   # only when Step 2 says ADC is needed
```
Chrome opens on its own for each, the user approves, done.

### Step 4: Retry
Re-run the command that originally failed.

## Rules (non-negotiable)

- **NEVER** skip `/notify-waiting` — the login blocks on the user.
- **NEVER** pass `--no-launch-browser`.
- **NEVER** use named pipes.
- **NEVER** capture or extract the URL.
- **NEVER** attempt manual PKCE/OAuth flows.
- **NEVER** treat `gcloud auth login` as sufficient when the trigger was a
  `pulumi`/GCS-backend error, or the error text is `invalid_grant`/`invalid_rapt`
  — always also run `gcloud auth application-default login` in that case.
