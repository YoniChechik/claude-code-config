---
name: "gcloud-auth"
description: "Re-authenticate an expired gcloud session. Use PROACTIVELY, without being asked by name, whenever a `gcloud`/`gsutil`/`bq` command fails on credentials — 'reauthentication required', 'invalid_grant', 'credentials not found', 'token has expired', 'Reauthentication failed', ADC/refresh-token errors — or whenever the user asks to re-auth, re-login, or log in to gcloud."
---

Re-auth is a single `gcloud auth login`. It opens Chrome automatically, the user approves, and the credentials are valid for ~1 day. Nothing else is needed.

## Process

### Step 1: Ping the user
Invoke the `/notify-waiting` skill FIRST. Step 2 blocks waiting for browser approval, so the user must be at their machine before it starts.

### Step 2: Log in
Run this directly via a **subagent Bash call**:
```bash
gcloud auth login
```
Chrome opens on its own, the user approves, done.

### Step 3: Retry
Re-run the command that originally failed.

## Rules (non-negotiable)

- **NEVER** skip `/notify-waiting` — the login blocks on the user.
- **NEVER** pass `--no-launch-browser`.
- **NEVER** use named pipes.
- **NEVER** capture or extract the URL.
- **NEVER** attempt manual PKCE/OAuth flows.
