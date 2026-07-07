#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "requests>=2.31",
# ]
# ///
"""
CI Watcher

Monitors GitHub Actions CI status for a branch and reports results via
webhook. Uses GitHub REST API directly with ETag conditional requests so
we can poll at 1s without burning API quota.

Args (positional, in this order to match SKILL.md):
    BRANCH         branch to watch
    PORT           webhook HTTP port
    SESSION_TOKEN  expected health-check token

State files (keyed by CLAUDE_CODE_SESSION_ID, full UUID):
    /tmp/ci_watch_state_{slot}    "<branch>:<state>" (single line)
    /tmp/ci_watch_pr_{slot}       PR JSON cache for status_line.sh
    /tmp/ci_watch_lock_{slot}     PID lock

Exit conditions:
    - branch not found on remote (1)
    - PR merged and main CI resolved for the merge commit (0)
    - PR merged but the default branch has no CI to trigger (0)
    - timeout waiting for main CI runs after merge (0)
    - session health check fails after retries (0)
"""

from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

# --- Configuration constants ---
POLL_INTERVAL = 1.0
SHA_RUNS_EMPTY_MAX = 120  # 120 * 1s = 2 min
MAIN_WAIT_MAX = 300  # 300 * 1s = 5 min
# Grace before flagging "no CI on main" when a SUCCESSFUL main-runs fetch shows
# zero workflow runs on the default branch. Still far shorter than the 5-min
# false wait (MAIN_WAIT_MAX) we're eliminating, but tolerant of a slow first-run
# registration. Combined with the main_fetch_ok gate, persistent API errors
# never flag no-main-ci — they fall through to the MAIN_WAIT_MAX timeout webhook.
NO_MAIN_CI_GRACE = 30  # 30 * 1s = 30s
HEALTH_RETRY_MAX = 5  # 5 attempts with 2s sleep between (~10s window)
HEALTH_RETRY_SLEEP = 2.0
# Stuck-pending detection: number of consecutive iterations a required check
# must remain un-emitted (with all emitted checks already completed) before we
# fire the STUCK_PENDING_REQUIRED_CHECKS notification.
STUCK_PENDING_MIN_ITERS = 60

# Module-level base dir for state files. Tests override this.
TMP_DIR = "/tmp"

GITHUB_API = "https://api.github.com"


# --- HTTP / API helpers ---


@dataclass
class ApiCache:
    etag: str = ""
    data: Any = None


def _gh_headers(token: str) -> dict[str, str]:
    # NOTE: intentionally omit "X-GitHub-Api-Version": "2022-11-28" — when sent
    # with certain GitHub OAuth user-tokens (gho_*), the API silently drops the
    # Authorization header and treats the request as anonymous, which returns
    # 404 on private-repo endpoints. Without the version header the same token
    # authenticates correctly.
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }


def api_get(url: str, cache: ApiCache, token: str) -> tuple[Any, bool]:
    """Conditional GET against the GitHub REST API.

    Returns ``(data, changed)``. On HTTP 304 returns the cached data with
    ``changed=False``. On any error returns the cached data with
    ``changed=False`` so the caller can keep marching.
    """
    headers = _gh_headers(token)
    if cache.etag:
        headers["If-None-Match"] = cache.etag
    try:
        resp = requests.get(url, headers=headers, timeout=10)
        if resp.status_code == 304:
            return cache.data, False
        resp.raise_for_status()
        cache.etag = resp.headers.get("ETag", "")
        cache.data = resp.json()
        return cache.data, True
    except Exception as e:  # noqa: BLE001 - we want to swallow & log
        print(f"[warn] api_get {url}: {e}", file=sys.stderr)
        return cache.data, False


def notify(port: int, message: str) -> None:
    """Send a webhook notification. Best-effort — silently swallow errors."""
    try:
        requests.post(f"http://127.0.0.1:{port}", data=message, timeout=5)
    except Exception:
        pass


def health_check(port: int, token: str) -> bool:
    """Verify the local webhook server is alive and bound to our session."""
    try:
        resp = requests.get(f"http://127.0.0.1:{port}/health", timeout=3)
        return resp.text == f"ok:{token}"
    except Exception:
        return False


# --- gh CLI fallbacks (used only on rare events) ---


def get_failed_job_names(run_id: int) -> list[str]:
    """Return job names with conclusion=='failure' for a single run."""
    result = subprocess.run(
        ["gh", "run", "view", str(run_id), "--json", "jobs"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    try:
        jobs = json.loads(result.stdout).get("jobs", [])
    except json.JSONDecodeError:
        return []
    return [j["name"] for j in jobs if j.get("conclusion") == "failure"]


def has_pending_checks(branch: str) -> bool:
    """Cross-validate that no check suites are still pending on this branch.

    Used to guard against false-positive "all passed" when workflows are
    queued but not yet visible in the runs API.
    """
    result = subprocess.run(
        ["gh", "pr", "checks", branch, "--json", "bucket"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    try:
        checks = json.loads(result.stdout)
    except json.JSONDecodeError:
        return False
    return any(c.get("bucket") == "pending" for c in checks)


# --- Stuck-pending required-checks detection ---


def get_required_contexts(
    owner: str, repo: str, default_branch: str
) -> tuple[list[str], int | None]:
    """Return (required_check_contexts, ruleset_id) for the default branch.

    Reads the active branch-protection ruleset via ``gh api``. Returns
    ``([], None)`` on any error — callers MUST treat empty as "unknown, do
    not trigger stuck-pending detection" rather than "no requirements".
    Errors are logged to stderr; we never silently swallow.
    """
    try:
        result = subprocess.run(
            [
                "gh",
                "api",
                f"/repos/{owner}/{repo}/rules/branches/{default_branch}",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"[warn] get_required_contexts gh api failed: {e}", file=sys.stderr)
        return [], None
    if result.returncode != 0:
        print(
            f"[warn] get_required_contexts gh api non-zero: {result.stderr.strip()}",
            file=sys.stderr,
        )
        return [], None
    try:
        rules = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"[warn] get_required_contexts JSON decode failed: {e}", file=sys.stderr)
        return [], None
    for rule in rules:
        if rule.get("type") != "required_status_checks":
            continue
        params = rule.get("parameters") or {}
        contexts = [
            c.get("context", "")
            for c in (params.get("required_status_checks") or [])
            if c.get("context")
        ]
        return contexts, rule.get("ruleset_id")
    return [], None


def get_emitted_check_names(pr_number: int) -> tuple[set[str], bool]:
    """Return (emitted_check_name_set, all_emitted_complete).

    Uses ``gh pr view --json statusCheckRollup``. ``all_emitted_complete`` is
    True iff every entry's ``status``/``state`` is COMPLETED (CheckRun) or
    has a non-PENDING ``state`` (StatusContext). Returns ``(set(), False)``
    on error so callers don't trigger stuck-pending on a stale poll.
    """
    try:
        result = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                str(pr_number),
                "--json",
                "statusCheckRollup",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"[warn] get_emitted_check_names gh failed: {e}", file=sys.stderr)
        return set(), False
    if result.returncode != 0:
        print(
            f"[warn] get_emitted_check_names gh non-zero: {result.stderr.strip()}",
            file=sys.stderr,
        )
        return set(), False
    try:
        rollup = json.loads(result.stdout).get("statusCheckRollup", [])
    except json.JSONDecodeError as e:
        print(f"[warn] get_emitted_check_names JSON decode: {e}", file=sys.stderr)
        return set(), False
    names: set[str] = set()
    all_complete = True
    for item in rollup:
        # CheckRun uses .name + .status; StatusContext uses .context + .state.
        name = item.get("name") or item.get("context") or ""
        if name:
            names.add(name)
        status = (item.get("status") or "").upper()
        state = (item.get("state") or "").upper()
        if status:
            if status != "COMPLETED":
                all_complete = False
        elif state in ("PENDING", "EXPECTED"):
            all_complete = False
    return names, all_complete


def detect_stuck_pending(
    owner: str,
    repo: str,
    default_branch: str,
    pr_number: int,
) -> tuple[frozenset[str], int | None, bool]:
    """Compute (stuck_required_check_names, ruleset_id, emitted_all_complete).

    ``stuck`` = required contexts from the ruleset that are NOT present in
    the PR's emitted check rollup. Callers should additionally gate on
    ``emitted_all_complete`` to avoid false positives while upstream jobs
    are still running.
    """
    required, ruleset_id = get_required_contexts(owner, repo, default_branch)
    if not required:
        return frozenset(), ruleset_id, False
    emitted, all_complete = get_emitted_check_names(pr_number)
    if not emitted:
        return frozenset(), ruleset_id, False
    stuck = frozenset(r for r in required if r not in emitted)
    return stuck, ruleset_id, all_complete


def _stuck_pending_message(
    branch: str,
    owner: str,
    repo: str,
    stuck: frozenset[str],
    ruleset_id: int | None,
) -> str:
    """Build the webhook payload for STUCK_PENDING_REQUIRED_CHECKS."""
    names_block = "\n".join(f"  - {n}" for n in sorted(stuck))
    ruleset_ref = str(ruleset_id) if ruleset_id is not None else "<RULESET_ID>"
    return (
        f"CI FAILURE on branch {branch}: STUCK_PENDING_REQUIRED_CHECKS\n"
        f"Required status checks have been stuck in 'Expected — Waiting for "
        f"status' state while all emitted checks are complete.\n\n"
        f"Stuck checks ({len(stuck)}):\n"
        f"{names_block}\n\n"
        f"RECOMMENDATION:\n"
        f"Required status checks stuck waiting (workflow/job display names "
        f"likely changed but the branch protection ruleset still references "
        f"old names). Two fixes:\n\n"
        f"1. Admin-merge the PR — accept the stuck pending. After merge, the "
        f"infra-github Pulumi stack will redeploy and update the ruleset to "
        f"require the new names.\n\n"
        f"2. Update the ruleset manually before merging:\n"
        f"     gh api /repos/{owner}/{repo}/rulesets/{ruleset_ref} --jq "
        f"'.rules[] |\n"
        f'       select(.type == "required_status_checks") |\n'
        f"       .parameters.required_status_checks'\n"
        f"   then PATCH the contexts array to match the actual emitted check "
        f"names.\n\n"
        f"3. Restructure the workflow so the emitted names match the ruleset "
        f"(e.g., remove reusable-workflow nesting that adds parent-job "
        f"prefixes)."
    )


def check_stuck_pending(
    state: WatchState,
    owner: str,
    repo: str,
    default_branch: str,
    pr_number: int | None,
    port: int,
) -> None:
    """Fire STUCK_PENDING_REQUIRED_CHECKS notification on rising edge.

    Trigger predicate (all must hold):
      * PR exists and has a number.
      * Ruleset is readable AND lists required contexts.
      * Every emitted check is completed (no PENDING/EXPECTED) — guards
        against an upstream still running.
      * Stuck set is non-empty AND has been the same set for
        ``STUCK_PENDING_MIN_ITERS`` consecutive iterations (~60s).
      * We haven't already reported it for this SHA.
    """
    if state.reported_stuck_pending or pr_number is None:
        return
    stuck, ruleset_id, all_complete = detect_stuck_pending(
        owner, repo, default_branch, pr_number
    )
    # Reset the streak whenever the set churns or emitted-set is incomplete.
    if not stuck or not all_complete:
        state.stuck_pending_iters = 0
        state.stuck_pending_names = frozenset()
        return
    if stuck != state.stuck_pending_names:
        state.stuck_pending_names = stuck
        state.stuck_pending_iters = 1
        return
    state.stuck_pending_iters += 1
    if state.stuck_pending_iters < STUCK_PENDING_MIN_ITERS:
        return
    msg = _stuck_pending_message(state.branch, owner, repo, stuck, ruleset_id)
    notify(port, msg)
    write_state(state.slot, state.branch, "stuck-pending")
    state.reported_stuck_pending = True


# --- Pure helpers ---


def is_conflicting(pr: dict) -> bool:
    return pr.get("mergeable_state") in ("dirty", "conflicting")


def is_behind(pr: dict) -> bool:
    return pr.get("mergeable_state") == "behind"


def is_merged(pr: dict) -> bool:
    return pr.get("state") == "closed" and pr.get("merged") is True


def get_merge_commit_sha(pr: dict) -> str:
    return pr.get("merge_commit_sha") or ""


def get_sha_runs(all_runs: list, sha: str) -> list:
    """Filter runs to a SHA, then keep only the highest-id run per workflow name."""
    sha_runs = [r for r in all_runs if r.get("head_sha") == sha]
    by_name: dict[str, dict] = {}
    for r in sha_runs:
        name = r.get("name", "")
        if name not in by_name or r["id"] > by_name[name]["id"]:
            by_name[name] = r
    return list(by_name.values())


def make_pr_cache(pr: dict) -> dict:
    """Build the JSON shape that status_line.sh expects."""
    state = pr.get("state", "")
    return {
        "url": pr.get("html_url", ""),
        "number": pr.get("number", ""),
        "state": "OPEN" if state == "open" else state.upper(),
        "mergeable": pr.get("mergeable"),
        "mergeStateStatus": pr.get("mergeable_state", "").upper(),
        "mergeCommit": (
            {"oid": pr["merge_commit_sha"]} if pr.get("merge_commit_sha") else None
        ),
    }


# --- File writers ---


def _state_path(slot: str) -> Path:
    return Path(TMP_DIR) / f"ci_watch_state_{slot}"


def _pr_path(slot: str) -> Path:
    return Path(TMP_DIR) / f"ci_watch_pr_{slot}"


def _lock_path(slot: str) -> Path:
    return Path(TMP_DIR) / f"ci_watch_lock_{slot}"


def _kill_path(slot: str) -> Path:
    return Path(TMP_DIR) / f"ci_watch_kill_{slot}"


def write_state(slot: str, branch: str, value: str) -> None:
    """Atomic write of '<branch>:<state>'."""
    print(f"[ci_watch] write_state -> {value!r}", flush=True)
    path = _state_path(slot)
    fd, tmp = tempfile.mkstemp(prefix=f"ci_watch_state_{slot}.", dir=TMP_DIR)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(f"{branch}:{value}")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def write_pr_cache(slot: str, data: dict) -> None:
    path = _pr_path(slot)
    fd, tmp = tempfile.mkstemp(prefix=f"ci_watch_pr_{slot}.", dir=TMP_DIR)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


# --- Lock handling ---


def acquire_lock(slot: str) -> None:
    """Kill any stale predecessor and take the lock for this slot."""
    lock_path = _lock_path(slot)
    if lock_path.exists():
        try:
            old_pid = int(lock_path.read_text().strip())
            result = subprocess.run(
                ["ps", "-p", str(old_pid), "-o", "args="],
                capture_output=True,
                text=True,
            )
            if "ci_watch" in result.stdout:
                try:
                    os.kill(old_pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
                # Poll for exit, max 10s.
                for _ in range(10):
                    try:
                        os.kill(old_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(1)
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    lock_path.write_text(str(os.getpid()))
    try:
        os.unlink(_kill_path(slot))
    except FileNotFoundError:
        pass


# --- State container ---


class WatchState:
    """All mutable state for a single watch() invocation."""

    def __init__(
        self, branch: str, slot: str, latest_sha: str, default_branch: str
    ) -> None:
        self.branch = branch
        self.slot = slot
        self.latest_sha = latest_sha
        self.default_branch = default_branch

        self.reported_pass = False
        self.reported_fail = False
        self.terminal_run_ids: set[int] = set()
        self.reported_conflict = False
        self.reported_behind = False
        self.reported_no_runs = False
        self.reported_no_ci = False
        # Stuck-pending tracking. Counts consecutive iterations where the same
        # required-check name set has been un-emitted while all emitted checks
        # are complete. Resets to 0 whenever the stuck set changes or any
        # emitted check is still in-progress (so an upstream-still-running
        # situation can't false-positive).
        self.stuck_pending_iters = 0
        self.stuck_pending_names: frozenset[str] = frozenset()
        self.reported_stuck_pending = False

        self.merged = False
        self.merge_commit_sha = ""
        self.reported_main_pass = False
        self.reported_main_fail = False
        self.main_wait_iterations = 0
        self.sha_runs_empty_count = 0

        self.runs_cache = ApiCache()
        self.main_runs_cache = ApiCache()
        self.pr_cache_obj = ApiCache()
        self.single_pr_cache = ApiCache()
        self.commit_cache = ApiCache()

        self.keep_state_file = False


# --- Detection helpers ---


def detect_new_sha(state: WatchState, all_runs: list) -> None:
    """If the most recent run reports a new SHA, reset per-SHA reporting flags."""
    if not all_runs:
        return
    current = max(all_runs, key=lambda r: r.get("id", 0))
    current_sha = current.get("head_sha")
    if not current_sha:
        return
    if current_sha != state.latest_sha:
        print(
            f"New push detected on branch '{state.branch}' "
            f"(new SHA: {current_sha}). Now tracking new CI run.",
            flush=True,
        )
        state.latest_sha = current_sha
        state.reported_pass = False
        state.reported_fail = False
        state.terminal_run_ids = set()
        state.reported_conflict = False
        state.reported_behind = False
        state.sha_runs_empty_count = 0
        state.reported_no_runs = False
        state.reported_no_ci = False
        state.stuck_pending_iters = 0
        state.stuck_pending_names = frozenset()
        state.reported_stuck_pending = False
        # Reset state file to "running" so the statusline reflects the new
        # in-progress run instead of remaining stuck on the previous
        # terminal state (passed/failed).
        write_state(state.slot, state.branch, "running")


def check_pr_condition(
    condition: bool,
    flag_name: str,
    state: WatchState,
    message: str,
    state_string: str,
    port: int,
) -> None:
    """Fire a webhook + write state once on rising edge; reset on falling edge."""
    flag = getattr(state, flag_name)
    if condition:
        if not flag:
            notify(port, message)
            setattr(state, flag_name, True)
            write_state(state.slot, state.branch, state_string)
    else:
        if flag:
            setattr(state, flag_name, False)
            # Condition cleared — restore state to "running" so the statusline
            # reflects the resolved state instead of staying stuck on the old
            # state string (e.g. "conflict" or "behind").
            write_state(state.slot, state.branch, "running")


def check_failures(context: str, sha_runs: list, state: WatchState, port: int) -> None:
    """Fire CI-failure webhook once per failure streak.

    ``context`` is "branch" or "main" — controls message wording, state string,
    and which reported_* flag we toggle.
    """
    # Conclusions that do NOT represent a code failure. Only "failure",
    # "timed_out", and "action_required" are treated as real CI failures.
    _pass_conclusions = {
        "success",  # code passed
        "skipped",  # path-filter / conditional skip
        "startup_failure",  # workflow never started (config/permission issue, zero jobs)
        "cancelled",  # manually cancelled, not a code failure
        "neutral",  # informational, not a failure
        "stale",  # superseded by a newer run
    }
    failed = [
        r
        for r in sha_runs
        if r.get("status") == "completed"
        and r.get("conclusion") not in _pass_conclusions
    ]
    if not failed:
        return

    flag_name = "reported_main_fail" if context == "main" else "reported_fail"
    if getattr(state, flag_name):
        return

    failed_names = ", ".join(r.get("name", "") for r in failed)
    failed_ids = [r["id"] for r in failed]

    all_failed_jobs: list[str] = []
    for run_id in failed_ids:
        all_failed_jobs.extend(get_failed_job_names(run_id))

    first_failed_id = failed_ids[0]

    if context == "main":
        msg = (
            f"CI on {state.default_branch} failed for merge of "
            f"'{state.branch}' (workflows: {failed_names})."
        )
    else:
        msg = f"CI failed on branch '{state.branch}' (workflows: {failed_names})."
    if all_failed_jobs:
        msg = f"{msg} Failed jobs: {' '.join(all_failed_jobs)} "
    msg = f"{msg} Run 'gh run view {first_failed_id} --log-failed' to get the logs."
    if context == "branch":
        msg = f"{msg} Delegate the fix to coder-agent."

    if context == "main":
        write_state(state.slot, state.branch, "merged-failed")
        notify(
            port,
            f"CI FAILURE on {state.default_branch} for merge of {state.branch}: {msg}",
        )
        state.reported_main_fail = True
    else:
        remote_head = get_remote_head_sha(state.branch)
        if remote_head is not None and remote_head != state.latest_sha:
            print(
                f"[ci_watch] skipping failure notification — "
                f"latest_sha {state.latest_sha[:7]} != remote HEAD {remote_head[:7]}",
                flush=True,
            )
            return
        notify(port, f"CI FAILURE on branch {state.branch}: {msg}")
        write_state(state.slot, state.branch, "failed")
        state.reported_fail = True
        state.terminal_run_ids = {
            r["id"] for r in sha_runs if r.get("status") == "completed"
        }


def check_all_passed(
    context: str, sha_runs: list, state: WatchState, mergeable_state: str, port: int
) -> None:
    """Fire CI-passed webhook once when every run is completed+success/skipped."""
    if not sha_runs:
        return
    # A run "passes" if its conclusion is not a code failure. Conclusions like
    # startup_failure (workflow never started), cancelled, neutral, and stale
    # are non-blocking — only "failure", "timed_out", and "action_required"
    # prevent the all-passed signal.
    _pass_conclusions = {
        "success",
        "skipped",
        "startup_failure",
        "cancelled",
        "neutral",
        "stale",
    }
    if any(
        r.get("status") != "completed" or r.get("conclusion") not in _pass_conclusions
        for r in sha_runs
    ):
        return

    flag_name = "reported_main_pass" if context == "main" else "reported_pass"
    if getattr(state, flag_name):
        return

    if context == "main":
        write_state(state.slot, state.branch, "merged-passed")
        notify(
            port,
            f"CI PASSED on {state.default_branch} after merge of branch {state.branch}",
        )
        state.reported_main_pass = True
        return

    if mergeable_state in ("CONFLICTING", "DIRTY", "BEHIND", "UNKNOWN", ""):
        return
    # Cross-check: gh run list only returns runs that have been created.
    # Workflows still queuing show up in `gh pr checks` as bucket=pending.
    if has_pending_checks(state.branch):
        return
    remote_head = get_remote_head_sha(state.branch)
    if remote_head is not None and remote_head != state.latest_sha:
        print(
            f"[ci_watch] skipping pass notification — "
            f"latest_sha {state.latest_sha[:7]} != remote HEAD {remote_head[:7]}",
            flush=True,
        )
        return
    notify(port, f"CI PASSED on branch {state.branch}")
    state.reported_pass = True
    state.terminal_run_ids = {r["id"] for r in sha_runs}
    write_state(state.slot, state.branch, "passed")


# --- Authentication & startup ---


def gh_token() -> str:
    return subprocess.run(
        ["gh", "auth", "token"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def repo_info() -> tuple[str, str, str]:
    """Returns (owner, repo, default_branch)."""
    result = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef"],
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(result.stdout)
    owner, repo = data["nameWithOwner"].split("/")
    default_branch = data["defaultBranchRef"]["name"] or "main"
    return owner, repo, default_branch


def get_remote_head_sha(branch: str) -> str | None:
    """Return current SHA of origin/<branch> via ``git ls-remote``.

    Returns ``None`` on any failure so callers can fail open (deliver the
    notification) rather than silence the watcher.
    """
    try:
        result = subprocess.run(
            ["git", "ls-remote", "origin", branch],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return None
        out = result.stdout.strip()
        if not out:
            return None
        sha = out.split()[0].strip()
        return sha or None
    except Exception:  # noqa: BLE001
        return None


def resolve_branch_sha(owner: str, repo: str, branch: str, token: str) -> str:
    """Fetch the latest commit SHA for ``branch``. Exits on failure.

    Retries on 404 — GitHub's API occasionally returns 404 from a cache layer
    even for branches that exist (observed empirically: 200/404 alternating on
    back-to-back calls). Retry up to 5 times with a 1s gap before giving up.
    """
    url = f"{GITHUB_API}/repos/{owner}/{repo}/commits/{branch}"
    headers = _gh_headers(token)
    last_status = None
    for attempt in range(5):
        resp = requests.get(url, headers=headers, timeout=10)
        last_status = resp.status_code
        if resp.status_code == 200:
            sha = resp.json().get("sha", "")
            if not sha:
                print(
                    f"Error: resolved SHA is empty for branch '{branch}'",
                    file=sys.stderr,
                )
                sys.exit(1)
            return sha
        if attempt < 4:
            time.sleep(1)
    print(
        f"Error: branch '{branch}' not found on remote (last status {last_status})",
        file=sys.stderr,
    )
    sys.exit(1)


# --- Main loop ---


def watch(
    branch: str,
    slot: str,
    port: int,
    session_token: str,
    owner: str,
    repo: str,
    default_branch: str,
    latest_sha: str,
) -> None:
    """Run the CI watch loop until a terminal condition fires."""
    state = WatchState(branch, slot, latest_sha, default_branch)

    runs_url = (
        f"{GITHUB_API}/repos/{owner}/{repo}/actions/runs?branch={branch}&per_page=100"
    )
    main_runs_url = (
        f"{GITHUB_API}/repos/{owner}/{repo}/actions/runs"
        f"?branch={default_branch}&per_page=100"
    )
    pr_url = (
        f"{GITHUB_API}/repos/{owner}/{repo}/pulls"
        f"?head={owner}:{branch}&state=all&per_page=5"
    )

    print(
        f"[ci_watch] starting watch loop branch={branch} "
        f"latest_sha={latest_sha[:8]} default_branch={default_branch} "
        f"pid={os.getpid()}",
        flush=True,
    )
    write_state(slot, branch, "running")

    def cleanup() -> None:
        if not state.keep_state_file:
            _state_path(slot).unlink(missing_ok=True)
            _pr_path(slot).unlink(missing_ok=True)
        _lock_path(slot).unlink(missing_ok=True)

    atexit.register(cleanup)

    def _signal_handler(signum: int, frame: object) -> None:
        sys.exit(0)

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    iter_count = 0
    last_heartbeat_iter = 0
    while True:
        iter_count += 1
        # --- Kill flag check (per-session manual stop) ---
        if _kill_path(slot).exists():
            print(
                f"[ci_watch] received kill signal for session {slot}; exiting",
                file=sys.stderr,
                flush=True,
            )
            try:
                os.unlink(_kill_path(slot))
            except FileNotFoundError:
                pass
            sys.exit(0)
        # --- Session health check (5x retries with 2s sleep ~ 10s window) ---
        # On Mac wake-from-sleep, the localhost webhook server may briefly be
        # unreachable while its process resumes.
        ok = False
        for _ in range(HEALTH_RETRY_MAX):
            if health_check(port, session_token):
                ok = True
                break
            time.sleep(HEALTH_RETRY_SLEEP)
        if not ok:
            print(
                f"Health check failed after {HEALTH_RETRY_MAX} attempts. Exiting.",
                flush=True,
            )
            return
        # Heartbeat every 30 iterations (~30s of polling time, longer with
        # API call latency) — proves the watcher is alive without flooding
        # the log. Useful for diagnosing "is it running?" without per-iteration
        # noise.
        if iter_count - last_heartbeat_iter >= 30:
            last_heartbeat_iter = iter_count
            print(
                f"[ci_watch] heartbeat iter={iter_count} merged={state.merged} "
                f"latest_sha={state.latest_sha[:8] if state.latest_sha else 'None'} "
                f"reported_fail={state.reported_fail} "
                f"reported_pass={state.reported_pass}",
                flush=True,
            )

        # --- Single combined PR fetch per loop iteration ---
        # The list endpoint (/pulls?head=...) does NOT return mergeable_state.
        # We fetch the single-PR endpoint (/pulls/{number}) for that field.
        pr_data, _ = api_get(pr_url, state.pr_cache_obj, gh_token_value())
        # pr_data is None when the API call failed (timeout / error) and
        # there was no cached data.  [] means "no PR exists".
        pr_fetch_failed = pr_data is None
        pr = pr_data[0] if pr_data else {}

        pr_number = pr.get("number")
        if pr_number:
            single_pr_url = f"{GITHUB_API}/repos/{owner}/{repo}/pulls/{pr_number}"
            single_pr_data, _ = api_get(
                single_pr_url, state.single_pr_cache, gh_token_value()
            )
            pr_detail = single_pr_data if isinstance(single_pr_data, dict) else {}
        else:
            pr_detail = pr

        if pr:
            write_pr_cache(slot, make_pr_cache(pr_detail or pr))

        merge_commit_oid = get_merge_commit_sha(pr_detail or pr)
        mergeable_state = (pr_detail or pr).get("mergeable_state", "").upper()

        # --- Detect merged ---
        # Use pr_detail (single-PR endpoint) — the list endpoint response is
        # ETag-cached and returns 304 forever after merge, so its 'state' and
        # 'merged' fields stay stale. The single-PR endpoint refetches.
        fresh_pr = pr_detail or pr
        if not state.merged and is_merged(fresh_pr) and merge_commit_oid:
            state.merged = True
            state.merge_commit_sha = merge_commit_oid
            write_state(slot, branch, "merging")
            # If behind/conflict/fail was reported in a previous iteration,
            # the merge supersedes it — send a corrective note so the user
            # knows the earlier alert was a transient race, not a real
            # problem.  (GitHub can briefly show mergeable_state:"behind"
            # while processing a squash-merge, causing a false-positive
            # "CI FAILURE: behind" one poll before the merge is visible.)
            superseded: list[str] = []
            if state.reported_behind:
                superseded.append("behind")
            if state.reported_conflict:
                superseded.append("conflict")
            if state.reported_fail:
                superseded.append("CI failure")
            suffix = ""
            if superseded:
                suffix = (
                    f" (previous {'/'.join(superseded)} alert was a transient"
                    f" race condition — disregard)"
                )
            notify(port, f"PR #{pr_number} merged to {default_branch}{suffix}")
            print(
                f"PR for branch '{branch}' has been merged "
                f"(merge commit: {state.merge_commit_sha}). "
                f"Now tracking CI on {default_branch}."
            )

        # --- Detect closed without merge ---
        # PR closed (state=closed) but not merged — user closed it manually.
        # Notify, persist final state, and exit cleanly.
        if (
            not state.merged
            and fresh_pr.get("state") == "closed"
            and not fresh_pr.get("merged")
        ):
            notify(port, f"PR closed without merge on branch {branch}")
            write_state(slot, branch, "closed")
            state.keep_state_file = True
            print(f"PR for branch '{branch}' closed without merge. Exiting.")
            return

        # --- Merged path: track main CI for the merge commit ---
        if state.merged:
            # Refresh mtime so statusline freshness gate doesn't drop us.
            write_state(slot, branch, "merging")

            main_runs_data, _ = api_get(
                main_runs_url, state.main_runs_cache, gh_token_value()
            )
            # api_get returns None (its default cache.data) when the fetch
            # failed with no cached payload — indistinguishable from a genuine
            # empty result once coerced to []. Track the success signal so a
            # transient API hiccup can't masquerade as "no CI on main".
            main_fetch_ok = main_runs_data is not None
            all_main_runs = (main_runs_data or {}).get("workflow_runs", [])
            # Filter out Dependabot's dependency-graph runs ("event":"dynamic",
            # path "dynamic/dependabot/..."). They're triggered on every merge
            # to main, can stay in_progress for a long time, and don't gate
            # the merge — leaving them in the gating set means the watcher
            # hangs in "merging" forever even though the real CI passed.
            gating_main_runs = [
                r
                for r in all_main_runs
                if r.get("event") != "dynamic"
                and not (r.get("path", "").startswith("dynamic/"))
            ]
            sha_runs = get_sha_runs(gating_main_runs, state.merge_commit_sha)

            if not sha_runs:
                # Only count toward timeout once the merge commit is visible
                # on the default branch — otherwise eventual consistency would
                # race us into a false 5-min timeout.
                commit_url = (
                    f"{GITHUB_API}/repos/{owner}/{repo}/commits/"
                    f"{state.merge_commit_sha}"
                )
                try:
                    resp = requests.get(
                        commit_url,
                        headers=_gh_headers(gh_token_value()),
                        timeout=10,
                    )
                    visible = resp.status_code == 200
                except Exception:
                    visible = False
                if visible:
                    state.main_wait_iterations += 1
                    # A SUCCESSFUL fetch that returns zero workflow runs on the
                    # default branch means the repo has no CI on main, so the
                    # merge will never trigger a run. Flag it promptly (after a
                    # short grace for runs to first register) instead of burning
                    # the full MAIN_WAIT_MAX timeout. Gate on main_fetch_ok so a
                    # persistent API failure (which also yields an empty list)
                    # does NOT flag no-main-ci — it keeps advancing the shared
                    # counter and falls through to the MAIN_WAIT_MAX timeout,
                    # which fires the actionable "check manually" webhook. When
                    # main DOES have runs (for other commits) but none for our
                    # merge commit, CI exists and is merely slow to register, so
                    # we also fall through to the timeout. No webhook for the
                    # no-main-ci case — mirroring the no-CI-branch case, the
                    # "ci: no main ci" statusline flag is enough.
                    if (
                        main_fetch_ok
                        and not all_main_runs
                        and state.main_wait_iterations >= NO_MAIN_CI_GRACE
                    ):
                        write_state(slot, branch, "no-main-ci")
                        state.keep_state_file = True
                        print(
                            f"No CI on {default_branch} for merge of "
                            f"'{branch}' — nothing to watch. Exiting."
                        )
                        return
                    if state.main_wait_iterations >= MAIN_WAIT_MAX:
                        notify(
                            port,
                            f"⚠️ No CI runs found on {default_branch} "
                            f"for merge commit of {branch} after "
                            f"{int(MAIN_WAIT_MAX * POLL_INTERVAL)}s. "
                            f"Check manually.",
                        )
                        write_state(slot, branch, "timeout")
                        state.keep_state_file = True
                        print("Timed out waiting for main CI runs. Exiting.")
                        return
                else:
                    state.main_wait_iterations = 0
                time.sleep(POLL_INTERVAL)
                continue

            state.main_wait_iterations = 0
            check_failures("main", sha_runs, state, port)
            check_all_passed("main", sha_runs, state, mergeable_state, port)

            if state.reported_main_pass or state.reported_main_fail:
                print(f"Main CI resolved for merge of '{branch}'. Exiting.")
                state.keep_state_file = True
                return

            time.sleep(POLL_INTERVAL)
            continue

        # --- Branch tracking path ---
        # Guard: if the PR list endpoint failed (returned None — API
        # timeout / network error with no cached data), we cannot tell
        # whether the PR is still open or has been merged.  Skip
        # conflict/behind/failure checks for this iteration — the merge
        # detection above also couldn't run, so firing a failure now
        # risks a false positive (the PR might already be merged but we
        # just can't see it).
        # When the endpoint returned [] (no PR exists) or a PR dict
        # (PR fetched successfully), checks proceed normally.
        pr_data_available = not pr_fetch_failed

        runs_data, _ = api_get(runs_url, state.runs_cache, gh_token_value())
        all_runs = (runs_data or {}).get("workflow_runs", [])

        if pr_data_available:
            check_pr_condition(
                is_conflicting(pr_detail or pr),
                "reported_conflict",
                state,
                f"CI FAILURE on branch {branch}: PR has merge conflicts. "
                f"Delegate the fix to coder-agent.",
                "conflict",
                port,
            )
            check_pr_condition(
                is_behind(pr_detail or pr),
                "reported_behind",
                state,
                f"CI FAILURE on branch {branch}: PR is behind the base branch "
                f"and needs to be updated. Run /sync to update the branch.",
                "behind",
                port,
            )

        if not all_runs:
            # Zero workflow_runs for this branch. Either the repo genuinely has
            # no CI, or CI is expected but hasn't appeared yet (queuing, or
            # required checks configured). Use the same grace period as the
            # per-SHA no-runs timeout. After the grace period, treat it as a
            # terminal "no-ci" (pass-equivalent) state UNLESS the PR's merge
            # gate signals that checks ARE expected — for an open PR a
            # BLOCKED/UNKNOWN/empty mergeable_state means required checks are
            # pending, so CI exists and we must keep waiting rather than
            # mislabel it as no-ci. With no PR there is no merge gate to wait
            # on, so empty runs genuinely mean no CI.
            state.sha_runs_empty_count += 1
            checks_expected = (
                pr_data_available
                and bool(pr_number)
                and mergeable_state in ("", "UNKNOWN", "BLOCKED")
            )
            if (
                not state.reported_no_ci
                and state.sha_runs_empty_count >= SHA_RUNS_EMPTY_MAX
                and not checks_expected
            ):
                state.reported_no_ci = True
                write_state(slot, branch, "no-ci")
                # No webhook here: "no CI to watch" is a no-op the user finds
                # noisy. The statusline "ci: none" flag is enough — genuine
                # pass/fail/behind notifications are unaffected.
            time.sleep(POLL_INTERVAL)
            continue

        detect_new_sha(state, all_runs)
        sha_runs = get_sha_runs(all_runs, state.latest_sha)

        if not sha_runs:
            state.sha_runs_empty_count += 1
            if (
                not state.reported_no_runs
                and state.sha_runs_empty_count >= SHA_RUNS_EMPTY_MAX
            ):
                state.reported_no_runs = True
                notify(
                    port,
                    f"⚠️ No CI runs visible for {branch} after 2 min "
                    f"— workflow may be missing or still queuing.",
                )
                write_state(slot, branch, "no-runs")
            time.sleep(POLL_INTERVAL)
            continue

        state.sha_runs_empty_count = 0
        if state.reported_no_runs:
            state.reported_no_runs = False
            write_state(slot, branch, "running")

        # Detect rerun on same SHA: a workflow we previously counted as terminal
        # has been replaced by a non-completed run (different id, same name).
        # Plain "any sibling not completed" was wrong — it re-fires every poll
        # when a slow workflow is still queued alongside an already-failed one.
        current_terminal_ids = {
            r["id"] for r in sha_runs if r.get("status") == "completed"
        }
        rerun_detected = state.terminal_run_ids and not state.terminal_run_ids.issubset(
            current_terminal_ids
        )
        if rerun_detected and (state.reported_fail or state.reported_pass):
            state.reported_fail = False
            state.reported_pass = False
            state.terminal_run_ids = set()
            write_state(slot, branch, "running")

        # Only fire branch failure/pass notifications when we have fresh PR
        # data confirming the PR is still open.  Without it, the PR might
        # already be merged (API timeout) and firing a failure here would be
        # a false positive.
        if pr_data_available:
            check_failures("branch", sha_runs, state, port)
        check_all_passed("branch", sha_runs, state, mergeable_state, port)

        # Stuck-pending required-checks detection. Only meaningful when the PR
        # is BLOCKED (so we know the merge gate is the cause) and we have a
        # PR number. Skipping when BLOCKED is absent avoids false positives
        # during normal in-progress windows.
        if pr_number and mergeable_state == "BLOCKED":
            check_stuck_pending(state, owner, repo, default_branch, pr_number, port)
        else:
            state.stuck_pending_iters = 0
            state.stuck_pending_names = frozenset()

        time.sleep(POLL_INTERVAL)


# Cache the gh auth token — it's stable for the life of the process and we
# don't want to fork `gh` on every API call.
_GH_TOKEN: str | None = None


def gh_token_value() -> str:
    global _GH_TOKEN
    if _GH_TOKEN is None:
        _GH_TOKEN = gh_token()
    return _GH_TOKEN


def main() -> None:
    # When stdout/stderr are redirected to a file (as in the SKILL launcher),
    # Python defaults to block buffering — log lines can sit in the buffer for
    # minutes before flushing, making the watcher look hung. Force line
    # buffering so each print() reaches the log file immediately.
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except (AttributeError, OSError):
        pass

    if len(sys.argv) < 4:
        print(
            "Usage: ci_watch.py <branch> <port> <session_token>",
            file=sys.stderr,
        )
        sys.exit(1)
    branch = sys.argv[1]
    port = int(sys.argv[2])
    session_token = sys.argv[3]

    slot = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if not slot:
        print(
            "Error: CLAUDE_CODE_SESSION_ID is unset. ci_watch must be launched "
            "from a Claude Code Bash subshell so the harness injects it.",
            file=sys.stderr,
        )
        sys.exit(2)

    acquire_lock(slot)

    token = gh_token_value()
    owner, repo, default_branch = repo_info()
    latest_sha = resolve_branch_sha(owner, repo, branch, token)

    watch(branch, slot, port, session_token, owner, repo, default_branch, latest_sha)


if __name__ == "__main__":
    main()
