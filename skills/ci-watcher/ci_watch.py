#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "requests>=2.31",
# ]
# ///
"""
CI Watcher

Monitors GitHub Actions CI status for a branch and reports results as plain
stdout lines. The process is launched by the /ci-watcher skill through Claude
Code's Monitor tool, which turns every stdout line into a session notification.
Stdout therefore carries notifications ONLY — every diagnostic goes to stderr.
Uses GitHub REST API directly with ETag conditional requests so we can poll at
1s without burning API quota.

Args (positional):
    BRANCH         branch to watch

State files (keyed by CLAUDE_CODE_SESSION_ID, full UUID):
    /tmp/ci_watch_state_{slot}    "<branch>:<state>" (single line), plus a
                                  ":monitor-detached@<epoch>" third field once
                                  a stdout write has failed — the watcher runs
                                  on but its notifications reach nobody
    /tmp/ci_watch_pr_{slot}       PR JSON cache for status_line.sh
    /tmp/ci_watch_lock_{slot}     PID lock; also the liveness oracle the
                                  /ci-watcher skill uses to decide whether a
                                  stored Monitor task id is stale
    /tmp/ci_watch_task_{slot}     Monitor task id; written by the /ci-watcher
                                  skill, not by this script
    /tmp/ci_watch_{slot}.log      this process's stderr, redirected by the
                                  Monitor command line

Exit conditions:
    - branch not found on remote (1)
    - PR merged and main CI resolved for the merge commit (0)
    - PR merged but the default branch has no CI to trigger (0)
    - PR merged in a repo with no workflow files at all (0)
    - timeout waiting for main CI runs after merge (0)
    - PR closed without merge (0)
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
# never flag no-main-ci — they fall through to the MAIN_WAIT_MAX timeout notification.
NO_MAIN_CI_GRACE = 30  # 30 * 1s = 30s
# Stuck-pending detection: number of consecutive iterations a required check
# must remain un-emitted (with all emitted checks already completed) before we
# fire the STUCK_PENDING_REQUIRED_CHECKS notification.
STUCK_PENDING_MIN_ITERS = 60

# Module-level base dir for state files. Tests override this.
TMP_DIR = "/tmp"

# Third field appended to the state file once stdout writes start failing, as
# "<branch>:<state>:monitor-detached@<epoch>". Readers (status_line.sh,
# _notify.sh, SKILL.md's liveness check) strip it before matching the state.
MONITOR_DETACHED_FIELD = "monitor-detached"

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


def _log_stderr(message: str) -> None:
    """Write one diagnostic line to stderr, dropping it if stderr is gone.

    Monitor's auto-detach closes BOTH pipes, so the stderr write inside a failed
    stdout write's handler can raise a second ``OSError`` and take the watcher
    down — exactly the death the handler exists to prevent. Every stderr write on
    a notification-failure path goes through here.
    """
    try:
        print(message, file=sys.stderr, flush=True)
    except OSError:
        pass


def notify(message: str) -> None:
    """Emit one notification as a single stdout write.

    The Monitor tool treats each stdout line as an event and batches lines
    emitted within 200ms into one notification, so a multi-line message stays
    one notification as long as it is written by a single ``print``.

    Best-effort: a dead reader (Monitor's auto-stop on high event volume, a
    closed pipe) must never take the watcher process down with it. The CRITICAL
    RULE of the /ci-watcher skill is that nothing kills this process by
    accident, so a failed write is dropped, not raised — but it IS recorded in
    the state file, so "alive and reporting" stays distinguishable from "alive
    and shouting into a closed pipe".
    """
    try:
        print(message, flush=True)
    except OSError as e:
        # Marker FIRST: stderr may be closed too, so anything written before the
        # marker is a chance to die with the failure unrecorded.
        _mark_monitor_detached()
        _log_stderr(f"[warn] notify failed: {e}")


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


def _get_branch_rules(owner: str, repo: str, default_branch: str) -> list | None:
    """Fetch the active branch-protection ruleset via ``gh api``.

    Shared by ``get_required_contexts`` and
    ``get_strict_required_status_checks_policy``. Returns ``None`` on any
    error (timeout, non-zero exit, bad JSON) so callers can fail toward
    their own safe default. Errors are logged to stderr; we never silently
    swallow.
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
        print(f"[warn] _get_branch_rules gh api failed: {e}", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(
            f"[warn] _get_branch_rules gh api non-zero: {result.stderr.strip()}",
            file=sys.stderr,
        )
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"[warn] _get_branch_rules JSON decode failed: {e}", file=sys.stderr)
        return None


def get_required_contexts(
    owner: str, repo: str, default_branch: str
) -> tuple[list[str], int | None]:
    """Return (required_check_contexts, ruleset_id) for the default branch.

    Reads the active branch-protection ruleset via ``gh api``. Returns
    ``([], None)`` on any error — callers MUST treat empty as "unknown, do
    not trigger stuck-pending detection" rather than "no requirements".
    """
    rules = _get_branch_rules(owner, repo, default_branch)
    if rules is None:
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


def get_strict_required_status_checks_policy(
    owner: str, repo: str, default_branch: str
) -> bool:
    """Return whether the default branch requires branches to be up to date
    before merging (GitHub's "Require branches to be up to date before
    merging" / ``strict_required_status_checks_policy``).

    Reads the same branch-protection ruleset as ``get_required_contexts``.
    Returns ``False`` on ANY error (missing rule, missing key, gh api
    failure, JSON parse error, etc.) — fail toward NOT alerting, since a
    false negative here (missing a real "needs update" alert) is far less
    disruptive than a false positive nagging to /sync a PR that GitHub will
    merge fine as-is.
    """
    rules = _get_branch_rules(owner, repo, default_branch)
    if rules is None:
        return False
    for rule in rules:
        if rule.get("type") != "required_status_checks":
            continue
        params = rule.get("parameters") or {}
        return params.get("strict_required_status_checks_policy") is True
    return False


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
    """Build the notification payload for STUCK_PENDING_REQUIRED_CHECKS."""
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
    notify(msg)
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


# Epoch of the FIRST failed stdout write, or None while the notification
# channel still works. Sticky by design — see _mark_monitor_detached.
_MONITOR_DETACHED_AT: float | None = None
# (slot, branch, value) of the last write_state. notify() only receives a
# message, so this is how it re-stamps the right state file when a write fails.
_LAST_STATE: tuple[str, str, str] | None = None


def write_state(slot: str, branch: str, value: str) -> None:
    """Atomic write of '<branch>:<state>'.

    Once the notification channel has been seen broken, a third field
    ':monitor-detached@<epoch>' is appended so every state write keeps carrying
    the marker.
    """
    global _LAST_STATE
    _LAST_STATE = (slot, branch, value)
    _log_stderr(f"[ci_watch] write_state -> {value!r}")
    line = f"{branch}:{value}"
    if _MONITOR_DETACHED_AT is not None:
        line = f"{line}:{MONITOR_DETACHED_FIELD}@{int(_MONITOR_DETACHED_AT)}"
    path = _state_path(slot)
    fd, tmp = tempfile.mkstemp(prefix=f"ci_watch_state_{slot}.", dir=TMP_DIR)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(line)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def _mark_monitor_detached() -> None:
    """Persist "our notifications reach nobody" into the state file.

    Sticky, never cleared on a later successful write: Monitor auto-stops a task
    on its own side, which a plain ``print`` cannot detect, so a write that
    happens not to raise is no proof the channel came back — only an operator
    restart is. Same one-way-transition discipline as merge_commit_visible.
    """
    global _MONITOR_DETACHED_AT
    if _MONITOR_DETACHED_AT is not None:
        return
    _MONITOR_DETACHED_AT = time.time()
    if _LAST_STATE is None:
        # No state written yet; the first write_state will carry the marker.
        return
    slot, branch, value = _LAST_STATE
    try:
        write_state(slot, branch, value)
    except OSError as e:
        _log_stderr(f"[warn] could not persist monitor-detached marker: {e}")


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


def _wait_for_exit(pid: int, seconds: int) -> bool:
    """Poll ``pid`` at 1s intervals for up to ``seconds``. True once it is gone.

    ``PermissionError`` means the pid is alive but owned by someone we cannot
    signal — reported as "still there", since we can do nothing more to it.
    """
    for i in range(seconds + 1):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        if i < seconds:
            time.sleep(1)
    return False


def _is_ci_watch_pid(pid: int) -> bool:
    """True if ``pid`` currently runs a ci_watch process."""
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "args="],
        capture_output=True,
        text=True,
    )
    return "ci_watch" in result.stdout


def acquire_lock(slot: str) -> None:
    """Kill any stale predecessor and take the lock for this slot.

    SIGTERM, then SIGKILL if the predecessor ignores it. Writing our pid while
    the old watcher is still running would put TWO watchers on one slot, both
    writing the same state and PR-cache files, until the loser finally exits.
    """
    lock_path = _lock_path(slot)
    if lock_path.exists():
        try:
            old_pid = int(lock_path.read_text().strip())
            if _is_ci_watch_pid(old_pid):
                try:
                    os.kill(old_pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
                # Re-check identity after the wait: the predecessor may have
                # exited and the OS recycled its pid for an unrelated process,
                # which SIGKILL must never hit.
                if not _wait_for_exit(old_pid, 10) and _is_ci_watch_pid(old_pid):
                    # SIGTERM went unanswered for 10s (handler wedged, process
                    # stuck in a syscall). Escalate rather than start a second
                    # watcher on this slot.
                    try:
                        os.kill(old_pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                    if not _wait_for_exit(old_pid, 2):
                        # Same rule as the SIGTERM timeout above: a stuck
                        # predecessor must never block a relaunch forever. Warn
                        # loudly and take the lock anyway — release_lock's pid
                        # guard stops the loser unlinking our lockfile.
                        print(
                            f"[warn] acquire_lock: pid {old_pid} survived "
                            f"SIGTERM+SIGKILL; taking the lock anyway — two "
                            f"watchers may share slot {slot}",
                            file=sys.stderr,
                            flush=True,
                        )
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    lock_path.write_text(str(os.getpid()))


def _holds_lock(slot: str) -> bool:
    """True if the lockfile on disk still records OUR pid."""
    try:
        return int(_lock_path(slot).read_text().strip()) == os.getpid()
    except (OSError, ValueError):
        return False


def release_lock(slot: str) -> None:
    """Drop the lock, but only if it still holds OUR pid.

    ``acquire_lock`` gives up waiting for a predecessor after 10s and writes its
    own pid anyway; a predecessor that exits later would otherwise unlink the
    SUCCESSOR's lockfile. The /ci-watcher skill reads that file as its only
    liveness oracle, so a false DEAD would make it launch a second watcher.
    """
    if _holds_lock(slot):
        try:
            _lock_path(slot).unlink(missing_ok=True)
        except OSError:
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

        # Set once at watch() startup by detect_no_ci_configured(): the repo has
        # zero workflow files, so no CI run can EVER appear for this branch or
        # for the merge commit. Short-circuits both waiting phases.
        self.no_ci_configured = False
        # State string the statusline should fall back to whenever a transient
        # condition (conflict/behind/no-runs) clears. "running" normally,
        # "no-ci-configured" when there is no CI to run.
        self.base_state = "running"

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
        # Sticky once True: a merge commit that has been observed on the
        # default branch can never become un-merged, so a later transient
        # fetch failure must not un-set this or wipe out main_wait_iterations.
        self.merge_commit_visible = False

        self.runs_cache = ApiCache()
        self.main_runs_cache = ApiCache()
        self.pr_cache_obj = ApiCache()
        self.single_pr_cache = ApiCache()
        self.commit_cache = ApiCache()

        self.keep_state_file = False

        # Lazily fetched once per watch() invocation — whether the default
        # branch actually requires branches to be up to date before merging.
        # None means "not yet fetched"; see get_strict_policy_cached().
        self.strict_policy: bool | None = None


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
            file=sys.stderr,
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
        # Reset state file to the base state so the statusline reflects the
        # new in-progress run instead of remaining stuck on the previous
        # terminal state (passed/failed).
        write_state(state.slot, state.branch, state.base_state)


def get_strict_policy_cached(
    state: WatchState, owner: str, repo: str, default_branch: str
) -> bool:
    """Fetch-if-None-then-reuse wrapper around
    ``get_strict_required_status_checks_policy``.

    The setting can't change mid-watch in any way that matters, so we fetch
    it once per process lifetime instead of polling it every loop iteration.
    """
    if state.strict_policy is None:
        state.strict_policy = get_strict_required_status_checks_policy(
            owner, repo, default_branch
        )
    return state.strict_policy


def check_pr_condition(
    condition: bool,
    flag_name: str,
    state: WatchState,
    message: str,
    state_string: str,
) -> None:
    """Notify + write state once on rising edge; reset on falling edge."""
    flag = getattr(state, flag_name)
    if condition:
        if not flag:
            notify(message)
            setattr(state, flag_name, True)
            write_state(state.slot, state.branch, state_string)
    else:
        if flag:
            setattr(state, flag_name, False)
            # Condition cleared — restore the base state so the statusline
            # reflects the resolved state instead of staying stuck on the old
            # state string (e.g. "conflict" or "behind").
            write_state(state.slot, state.branch, state.base_state)


def check_failures(context: str, sha_runs: list, state: WatchState) -> None:
    """Fire the CI-failure notification once per failure streak.

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
        msg = f"{msg} Delegate the fix to a subagent."

    if context == "main":
        write_state(state.slot, state.branch, "merged-failed")
        notify(
            f"CI FAILURE on {state.default_branch} for merge of {state.branch}: {msg}"
        )
        state.reported_main_fail = True
    else:
        remote_head = get_remote_head_sha(state.branch)
        if remote_head is not None and remote_head != state.latest_sha:
            print(
                f"[ci_watch] skipping failure notification — "
                f"latest_sha {state.latest_sha[:7]} != remote HEAD {remote_head[:7]}",
                file=sys.stderr,
                flush=True,
            )
            return
        notify(f"CI FAILURE on branch {state.branch}: {msg}")
        write_state(state.slot, state.branch, "failed")
        state.reported_fail = True
        state.terminal_run_ids = {
            r["id"] for r in sha_runs if r.get("status") == "completed"
        }


def check_all_passed(
    context: str, sha_runs: list, state: WatchState, mergeable_state: str
) -> None:
    """Fire the CI-passed notification once when every run is completed+success/skipped."""
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
            f"CI PASSED on {state.default_branch} after merge of branch {state.branch}"
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
            file=sys.stderr,
            flush=True,
        )
        return
    notify(f"CI PASSED on branch {state.branch}")
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


def count_repo_workflows(owner: str, repo: str, token: str) -> int | None:
    """Return how many workflows the repo has registered, or None if unknown.

    ``GET /actions/workflows`` reports every workflow GitHub knows about for
    the repo (``total_count``), including disabled ones. Returns None on ANY
    error or unexpected payload — callers MUST treat None as "unknown" and
    fall back to the normal wait/timeout path, never as "no CI".
    """
    url = f"{GITHUB_API}/repos/{owner}/{repo}/actions/workflows?per_page=1"
    try:
        resp = requests.get(url, headers=_gh_headers(token), timeout=10)
        if resp.status_code != 200:
            print(
                f"[warn] count_repo_workflows HTTP {resp.status_code}",
                file=sys.stderr,
            )
            return None
        data = resp.json()
    except Exception as e:  # noqa: BLE001
        print(f"[warn] count_repo_workflows failed: {e}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        return None
    total = data.get("total_count")
    if not isinstance(total, int) or isinstance(total, bool):
        return None
    return total


def ref_has_workflow_files(owner: str, repo: str, ref: str, token: str) -> bool | None:
    """Whether ``ref`` contains at least one ``.github/workflows/*.y[a]ml`` file.

    404 means the directory does not exist on that ref -> False. Any other
    error or unexpected payload -> None ("unknown"), so callers fall back to
    the normal wait/timeout path.
    """
    url = f"{GITHUB_API}/repos/{owner}/{repo}/contents/.github/workflows?ref={ref}"
    try:
        resp = requests.get(url, headers=_gh_headers(token), timeout=10)
        if resp.status_code == 404:
            return False
        if resp.status_code != 200:
            print(
                f"[warn] ref_has_workflow_files {ref} HTTP {resp.status_code}",
                file=sys.stderr,
            )
            return None
        entries = resp.json()
    except Exception as e:  # noqa: BLE001
        print(f"[warn] ref_has_workflow_files {ref} failed: {e}", file=sys.stderr)
        return None
    if not isinstance(entries, list):
        return None
    return any(
        isinstance(e, dict)
        and e.get("type") == "file"
        and str(e.get("name", "")).endswith((".yml", ".yaml"))
        for e in entries
    )


def detect_no_ci_configured(
    owner: str, repo: str, branch: str, default_branch: str, token: str
) -> bool:
    """True only when a CI run is STRUCTURALLY impossible for this repo.

    Three independent signals must all agree, and every one of them fails
    toward False (keep waiting) when it cannot be read:

      1. ``/actions/workflows`` reports total_count == 0 — GitHub has no
         workflow registered for the repo at all.
      2. The watched branch has no ``.github/workflows/*.y[a]ml`` file. A PR
         that INTRODUCES the first workflow would run it from the head ref,
         so the repo-level count alone is not enough.
      3. The default branch has no workflow file either (covers post-merge
         CI on the default branch).

    This is deliberately NOT the same as "no run has appeared yet": a repo
    with workflows that simply haven't triggered/queued still goes through the
    normal SHA_RUNS_EMPTY_MAX / MAIN_WAIT_MAX paths. Only zero workflow files
    makes a run impossible forever, which is what justifies short-circuiting
    both waiting phases.
    """
    total = count_repo_workflows(owner, repo, token)
    if total is None or total > 0:
        return False
    # dict.fromkeys de-dupes while keeping order (branch == default_branch when
    # watching main directly).
    for ref in dict.fromkeys((branch, default_branch)):
        has_files = ref_has_workflow_files(owner, repo, ref, token)
        if has_files is None or has_files:
            return False
    return True


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
        file=sys.stderr,
        flush=True,
    )
    write_state(slot, branch, "running")

    def cleanup() -> None:
        # Same pid guard as release_lock: acquire_lock can take a slot whose
        # predecessor never died, so a late-exiting predecessor must not wipe
        # the SUCCESSOR's live state file and PR cache.
        if not state.keep_state_file and _holds_lock(slot):
            _state_path(slot).unlink(missing_ok=True)
            _pr_path(slot).unlink(missing_ok=True)
        release_lock(slot)

    atexit.register(cleanup)

    def _signal_handler(signum: int, frame: object) -> None:
        sys.exit(0)

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    # --- One-shot "is there any CI at all?" probe ---
    # Done once, right after the state file exists and the signal handlers are
    # installed, and NEVER re-queried in the loop: workflow files can't appear
    # mid-watch in a way that matters (a push that adds one also creates runs,
    # which the normal path handles). A repo with zero workflow files can never
    # produce a run, so waiting SHA_RUNS_EMPTY_MAX (2 min) on the branch and
    # MAIN_WAIT_MAX (5 min) after the merge only delays an answer we already
    # have. One notification here replaces both waits.
    state.no_ci_configured = detect_no_ci_configured(
        owner, repo, branch, default_branch, gh_token_value()
    )
    if state.no_ci_configured:
        state.base_state = "no-ci-configured"
        write_state(slot, branch, state.base_state)
        notify(
            f"No CI configured in {owner}/{repo} — zero workflow files, so no "
            f"checks can run for {branch}. Nothing to wait for; safe to merge. "
            f"Still watching for the merge itself."
        )
        print(
            f"[ci_watch] no workflow files in {owner}/{repo} — skipping every "
            f"CI wait; watching for merge/close only.",
            file=sys.stderr,
            flush=True,
        )

    iter_count = 0
    last_heartbeat_iter = 0
    while True:
        iter_count += 1
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
                file=sys.stderr,
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
            write_state(
                slot, branch, state.base_state if state.no_ci_configured else "merging"
            )
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
            notify(f"PR #{pr_number} merged to {default_branch}{suffix}")
            print(
                f"PR for branch '{branch}' has been merged "
                f"(merge commit: {state.merge_commit_sha}). "
                f"Now tracking CI on {default_branch}.",
                file=sys.stderr,
                flush=True,
            )

        # --- Detect closed without merge ---
        # PR closed (state=closed) but not merged — user closed it manually.
        # Notify, persist final state, and exit cleanly.
        if (
            not state.merged
            and fresh_pr.get("state") == "closed"
            and not fresh_pr.get("merged")
        ):
            notify(f"PR closed without merge on branch {branch}")
            write_state(slot, branch, "closed")
            state.keep_state_file = True
            print(
                f"PR for branch '{branch}' closed without merge. Exiting.",
                file=sys.stderr,
                flush=True,
            )
            return

        # --- Merged path: track main CI for the merge commit ---
        if state.merged:
            # No workflow files anywhere in the repo: the merge commit can never
            # get a run, so skip the whole main-CI wait (NO_MAIN_CI_GRACE /
            # MAIN_WAIT_MAX) and finish on the merge itself. The merge
            # notification already went out one branch above.
            if state.no_ci_configured:
                write_state(slot, branch, "no-ci-configured")
                state.keep_state_file = True
                print(
                    f"Merge of '{branch}' observed and {owner}/{repo} has no "
                    f"workflow files — no main CI can run. Exiting.",
                    file=sys.stderr,
                    flush=True,
                )
                return

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
                # race us into a false 5-min timeout. Visibility is sticky: a
                # merge commit that GitHub has already shown us can't become
                # un-merged, so once True we skip the re-fetch entirely
                # instead of re-polling this endpoint (uncached, unlike every
                # other fetch in this loop) every second for the rest of the
                # watch. That also means a later transient failure/rate-limit
                # on this call can no longer erase main_wait_iterations
                # progress — previously it did, which could defer the
                # 5-minute MAIN_WAIT_MAX timeout by hours if this fetch got
                # flaky (e.g. from several concurrent ci_watch processes
                # sharing the same GitHub rate limit).
                if not state.merge_commit_visible:
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
                        if resp.status_code == 200:
                            state.merge_commit_visible = True
                        else:
                            print(
                                f"[warn] commit visibility check for "
                                f"{state.merge_commit_sha[:8]} returned "
                                f"HTTP {resp.status_code}",
                                file=sys.stderr,
                                flush=True,
                            )
                    except Exception as e:  # noqa: BLE001
                        print(
                            f"[warn] commit visibility check for "
                            f"{state.merge_commit_sha[:8]} failed: {e}",
                            file=sys.stderr,
                            flush=True,
                        )
                if state.merge_commit_visible:
                    state.main_wait_iterations += 1
                    # A SUCCESSFUL fetch that returns zero workflow runs on the
                    # default branch means the repo has no CI on main, so the
                    # merge will never trigger a run. Flag it promptly (after a
                    # short grace for runs to first register) instead of burning
                    # the full MAIN_WAIT_MAX timeout. Gate on main_fetch_ok so a
                    # persistent API failure (which also yields an empty list)
                    # does NOT flag no-main-ci — it keeps advancing the shared
                    # counter and falls through to the MAIN_WAIT_MAX timeout,
                    # which fires the actionable "check manually" notification.
                    # When main DOES have runs (for other commits) but none for
                    # our merge commit, CI exists and is merely slow to register,
                    # so we also fall through to the timeout. No notification for
                    # the no-main-ci case — mirroring the no-CI-branch case, the
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
                            f"'{branch}' — nothing to watch. Exiting.",
                            file=sys.stderr,
                            flush=True,
                        )
                        return
                    if state.main_wait_iterations >= MAIN_WAIT_MAX:
                        notify(
                            f"⚠️ No CI runs found on {default_branch} "
                            f"for merge commit of {branch} after "
                            f"{int(MAIN_WAIT_MAX * POLL_INTERVAL)}s. "
                            f"Check manually."
                        )
                        write_state(slot, branch, "timeout")
                        state.keep_state_file = True
                        print(
                            "Timed out waiting for main CI runs. Exiting.",
                            file=sys.stderr,
                            flush=True,
                        )
                        return
                time.sleep(POLL_INTERVAL)
                continue

            state.main_wait_iterations = 0
            check_failures("main", sha_runs, state)
            check_all_passed("main", sha_runs, state, mergeable_state)

            if state.reported_main_pass or state.reported_main_fail:
                print(
                    f"Main CI resolved for merge of '{branch}'. Exiting.",
                    file=sys.stderr,
                    flush=True,
                )
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

        if pr_data_available:
            check_pr_condition(
                is_conflicting(pr_detail or pr),
                "reported_conflict",
                state,
                f"CI FAILURE on branch {branch}: PR has merge conflicts. "
                f"Delegate the fix to a subagent.",
                "conflict",
            )
            # Only alert on "behind" when the repo's branch protection actually
            # requires branches to be up to date before merging. If that
            # setting is off, mergeable_state=behind doesn't block merging —
            # GitHub will merge it fine — so alerting would be a false
            # positive. Skip the check entirely when not strict: don't flip
            # reported_behind or write any "behind" state.
            if get_strict_policy_cached(state, owner, repo, default_branch):
                check_pr_condition(
                    is_behind(pr_detail or pr),
                    "reported_behind",
                    state,
                    f"CI FAILURE on branch {branch}: PR is behind the base "
                    f"branch and needs to be updated. Run /sync to update "
                    f"the branch.",
                    "behind",
                )

        # --- No CI configured: nothing to poll for ---
        # The repo has zero workflow files, so the runs endpoint can only ever
        # return an empty list. Skip it, and skip every CI-specific wait
        # (SHA_RUNS_EMPTY_MAX no-runs grace, pass/fail detection,
        # stuck-pending). Conflict/behind alerts above still run — they matter
        # for merging — and the loop stays alive to confirm the merge or close.
        if state.no_ci_configured:
            time.sleep(POLL_INTERVAL)
            continue

        runs_data, _ = api_get(runs_url, state.runs_cache, gh_token_value())
        all_runs = (runs_data or {}).get("workflow_runs", [])

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
                # No notification here: "no CI to watch" is a no-op the user finds
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
                    f"⚠️ No CI runs visible for {branch} after 2 min "
                    f"— workflow may be missing or still queuing."
                )
                write_state(slot, branch, "no-runs")
            time.sleep(POLL_INTERVAL)
            continue

        state.sha_runs_empty_count = 0
        if state.reported_no_runs:
            state.reported_no_runs = False
            write_state(slot, branch, state.base_state)

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
            write_state(slot, branch, state.base_state)

        # Only fire branch failure/pass notifications when we have fresh PR
        # data confirming the PR is still open.  Without it, the PR might
        # already be merged (API timeout) and firing a failure here would be
        # a false positive.
        if pr_data_available:
            check_failures("branch", sha_runs, state)
        check_all_passed("branch", sha_runs, state, mergeable_state)

        # Stuck-pending required-checks detection. Only meaningful when the PR
        # is BLOCKED (so we know the merge gate is the cause) and we have a
        # PR number. Skipping when BLOCKED is absent avoids false positives
        # during normal in-progress windows.
        if pr_number and mergeable_state == "BLOCKED":
            check_stuck_pending(state, owner, repo, default_branch, pr_number)
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
    # stdout is the Monitor event stream: each line becomes one session
    # notification, so it must reach the pipe as soon as it is written. Python
    # block-buffers a non-tty stdout by default, which would delay (or on a
    # SIGKILL, lose) notifications. stderr goes to the log file and gets line
    # buffering for the same "tail -f is not stale" reason.
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except (AttributeError, OSError):
        pass

    if len(sys.argv) != 2:
        print(
            "Usage: ci_watch.py <branch>",
            file=sys.stderr,
        )
        sys.exit(1)
    branch = sys.argv[1].strip()
    if not branch:
        # A Monitor command line built from an unsubstituted template expands
        # its placeholders to empty strings. Fail here instead of deep inside
        # the API layer with a confusing "branch not found".
        print(
            "Error: branch argument is empty.",
            file=sys.stderr,
        )
        sys.exit(1)

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

    watch(branch, slot, owner, repo, default_branch, latest_sha)


if __name__ == "__main__":
    main()
