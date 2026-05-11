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
HEALTH_RETRY_MAX = 5  # 5 attempts with 2s sleep between (~10s window)
HEALTH_RETRY_SLEEP = 2.0

# Module-level base dir for state files. Tests override this.
TMP_DIR = "/tmp"

GITHUB_API = "https://api.github.com"


# --- HTTP / API helpers ---


@dataclass
class ApiCache:
    etag: str = ""
    data: Any = None


def _gh_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
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
    failed = [
        r
        for r in sha_runs
        if r.get("status") == "completed" and r.get("conclusion") == "failure"
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
        notify(port, f"CI FAILURE on branch {state.branch}: {msg}")
        write_state(state.slot, state.branch, "failed")
        state.reported_fail = True
        state.terminal_run_ids = {
            r["id"] for r in sha_runs if r.get("status") == "completed"
        }


def check_all_passed(
    context: str, sha_runs: list, state: WatchState, mergeable_state: str, port: int
) -> None:
    """Fire CI-passed webhook once when every run is completed+success."""
    if not sha_runs:
        return
    if any(
        r.get("status") != "completed" or r.get("conclusion") != "success"
        for r in sha_runs
    ):
        return

    flag_name = "reported_main_pass" if context == "main" else "reported_pass"
    if getattr(state, flag_name):
        return

    if context == "main":
        write_state(state.slot, state.branch, "merged-passed")
        notify(
            port, f"✅ CI on {state.default_branch} passed for merge of {state.branch}"
        )
        state.reported_main_pass = True
        return

    if mergeable_state in ("CONFLICTING", "DIRTY", "BEHIND", "UNKNOWN", ""):
        return
    # Cross-check: gh run list only returns runs that have been created.
    # Workflows still queuing show up in `gh pr checks` as bucket=pending.
    if has_pending_checks(state.branch):
        return
    notify(port, f"✅ CI passed on branch {state.branch}")
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


def resolve_branch_sha(owner: str, repo: str, branch: str, token: str) -> str:
    """Fetch the latest commit SHA for ``branch``. Exits on failure."""
    resp = requests.get(
        f"{GITHUB_API}/repos/{owner}/{repo}/commits/{branch}",
        headers=_gh_headers(token),
        timeout=10,
    )
    if resp.status_code != 200:
        print(f"Error: branch '{branch}' not found on remote", file=sys.stderr)
        sys.exit(1)
    sha = resp.json().get("sha", "")
    if not sha:
        print(f"Error: resolved SHA is empty for branch '{branch}'", file=sys.stderr)
        sys.exit(1)
    return sha


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
        runs_data, _ = api_get(runs_url, state.runs_cache, gh_token_value())
        all_runs = (runs_data or {}).get("workflow_runs", [])

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

        check_failures("branch", sha_runs, state, port)
        check_all_passed("branch", sha_runs, state, mergeable_state, port)

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
