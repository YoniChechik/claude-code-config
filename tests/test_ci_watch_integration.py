# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "requests>=2.31",
#   "pytest>=8",
# ]
# ///
"""Integration tests for ci_watch.

Tests import the ci_watch module directly. The module's network calls
(``api_get``, ``notify``, ``health_check``) are mocked, and ``time.sleep``
is patched to break the watch loop after a controlled number of iterations.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Make the scripts dir importable.
SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import ci_watch  # noqa: E402


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

def test_get_sha_runs_deduplication():
    runs = [
        {"id": 1, "name": "build", "head_sha": "abc"},
        {"id": 5, "name": "build", "head_sha": "abc"},
        {"id": 3, "name": "build", "head_sha": "abc"},
        {"id": 2, "name": "test",  "head_sha": "abc"},
    ]
    out = ci_watch.get_sha_runs(runs, "abc")
    out_by_name = {r["name"]: r for r in out}
    assert out_by_name["build"]["id"] == 5
    assert out_by_name["test"]["id"] == 2
    assert len(out) == 2


def test_get_sha_runs_filters_by_sha():
    runs = [
        {"id": 1, "name": "build", "head_sha": "abc"},
        {"id": 2, "name": "build", "head_sha": "xyz"},
    ]
    out = ci_watch.get_sha_runs(runs, "abc")
    assert len(out) == 1
    assert out[0]["id"] == 1


def test_is_conflicting():
    assert ci_watch.is_conflicting({"mergeable_state": "dirty"}) is True
    assert ci_watch.is_conflicting({"mergeable_state": "conflicting"}) is True
    assert ci_watch.is_conflicting({"mergeable_state": "clean"}) is False
    assert ci_watch.is_conflicting({}) is False


def test_is_behind():
    assert ci_watch.is_behind({"mergeable_state": "behind"}) is True
    assert ci_watch.is_behind({"mergeable_state": "clean"}) is False
    assert ci_watch.is_behind({}) is False


def test_is_merged():
    assert ci_watch.is_merged({"state": "closed", "merged": True}) is True
    assert ci_watch.is_merged({"state": "closed", "merged": False}) is False
    assert ci_watch.is_merged({"state": "open", "merged": True}) is False


def test_make_pr_cache_state_uppercase():
    pr = {
        "html_url": "https://example.com/pr/1",
        "number": 1,
        "state": "open",
        "mergeable": True,
        "mergeable_state": "clean",
        "merge_commit_sha": "deadbeef",
    }
    cache = ci_watch.make_pr_cache(pr)
    assert cache["state"] == "OPEN"
    assert cache["mergeStateStatus"] == "CLEAN"
    assert cache["mergeCommit"] == {"oid": "deadbeef"}
    assert cache["url"] == "https://example.com/pr/1"
    assert cache["number"] == 1


def test_make_pr_cache_no_merge_commit():
    pr = {"state": "open", "mergeable_state": ""}
    cache = ci_watch.make_pr_cache(pr)
    assert cache["mergeCommit"] is None


# ---------------------------------------------------------------------------
# ETag / api_get
# ---------------------------------------------------------------------------

def test_etag_304_uses_cache():
    cache = ci_watch.ApiCache(etag='"e1"', data={"prev": True})

    fake_resp = MagicMock(status_code=304, headers={})
    with patch.object(ci_watch.requests, "get", return_value=fake_resp) as g:
        data, changed = ci_watch.api_get(
            "https://api.github.com/x", cache, "tok")
    assert data == {"prev": True}
    assert changed is False
    # And the conditional header was sent.
    headers = g.call_args.kwargs["headers"]
    assert headers["If-None-Match"] == '"e1"'


def test_api_get_200_updates_cache():
    cache = ci_watch.ApiCache()
    fake_resp = MagicMock(
        status_code=200,
        headers={"ETag": '"new"'},
    )
    fake_resp.json.return_value = {"hello": "world"}
    fake_resp.raise_for_status = lambda: None
    with patch.object(ci_watch.requests, "get", return_value=fake_resp):
        data, changed = ci_watch.api_get(
            "https://api.github.com/x", cache, "tok")
    assert data == {"hello": "world"}
    assert changed is True
    assert cache.etag == '"new"'
    assert cache.data == {"hello": "world"}


def test_api_get_error_returns_cached():
    cache = ci_watch.ApiCache(etag='"e1"', data={"prev": True})
    with patch.object(ci_watch.requests, "get", side_effect=Exception("boom")):
        data, changed = ci_watch.api_get(
            "https://api.github.com/x", cache, "tok")
    assert data == {"prev": True}
    assert changed is False


# ---------------------------------------------------------------------------
# Watch loop tests
# ---------------------------------------------------------------------------

class StopLoop(Exception):
    """Raised by mocked time.sleep to break the watch loop."""


def make_sleep_breaker(max_calls: int):
    state = {"n": 0}
    def fake_sleep(_t):
        state["n"] += 1
        if state["n"] >= max_calls:
            raise StopLoop
    return fake_sleep, state


def run_watch(tmp_dir: str, branch: str = "feat",
              port: int = 12345, token: str = "tk",
              owner: str = "o", repo: str = "r",
              default_branch: str = "main",
              latest_sha: str = "sha-old",
              api_get_side_effect=None,
              has_pending=False,
              health_ok=True,
              max_sleeps: int = 3) -> dict:
    """Drive ``ci_watch.watch`` for ``max_sleeps`` iterations.

    Returns a dict with ``notify_calls``, ``state_file_path``, ``state_value``.
    """
    fake_sleep, _ = make_sleep_breaker(max_sleeps)

    notify_calls: list[tuple[int, str]] = []
    def fake_notify(p, m):
        notify_calls.append((p, m))

    with patch.object(ci_watch, "TMP_DIR", tmp_dir), \
         patch.object(ci_watch, "_GH_TOKEN", "tk-cached"), \
         patch.object(ci_watch.time, "sleep", fake_sleep), \
         patch.object(ci_watch, "api_get", side_effect=api_get_side_effect), \
         patch.object(ci_watch, "notify", side_effect=fake_notify), \
         patch.object(ci_watch, "health_check", return_value=health_ok), \
         patch.object(ci_watch, "has_pending_checks", return_value=has_pending), \
         patch.object(ci_watch, "get_failed_job_names", return_value=[]), \
         patch.object(ci_watch.requests, "get") as commit_get:
        commit_get.return_value = MagicMock(status_code=200)
        try:
            ci_watch.watch(
                branch=branch,
                branch_key=branch,
                port=port,
                session_token=token,
                owner=owner,
                repo=repo,
                default_branch=default_branch,
                latest_sha=latest_sha,
            )
        except StopLoop:
            pass

    state_path = Path(tmp_dir) / f"ci_watch_state_{branch}"
    state_value = state_path.read_text() if state_path.exists() else None
    return {
        "notify_calls": notify_calls,
        "state_value": state_value,
    }


def make_api_get(pr=None, runs=None, main_runs=None):
    """Build an api_get side_effect that routes by URL keyword."""
    pr = pr if pr is not None else []
    runs = runs if runs is not None else {"workflow_runs": []}
    main_runs = main_runs if main_runs is not None else {"workflow_runs": []}

    def side_effect(url, cache, token):
        if "/pulls" in url:
            return pr, True
        if "/actions/runs" in url:
            # Distinguish by which branch is in URL.
            if "branch=main" in url:
                return main_runs, True
            return runs, True
        return None, False
    return side_effect


def test_ci_running_state(tmp_path):
    runs = {"workflow_runs": [
        {"id": 1, "name": "build", "head_sha": "sha-old",
         "status": "in_progress", "conclusion": None},
    ]}
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    # No pass/fail webhook fired; state stays 'running'.
    pass_msgs = [m for _, m in out["notify_calls"] if "passed" in m.lower()]
    fail_msgs = [m for _, m in out["notify_calls"] if "failure" in m.lower()]
    assert pass_msgs == []
    assert fail_msgs == []
    assert out["state_value"] == "running"


def test_ci_passes(tmp_path):
    runs = {"workflow_runs": [
        {"id": 1, "name": "build", "head_sha": "sha-old",
         "status": "completed", "conclusion": "success"},
    ]}
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
        has_pending=False,
    )
    assert out["state_value"] == "passed"
    assert any("✅ CI passed" in m for _, m in out["notify_calls"])


def test_ci_fails(tmp_path):
    runs = {"workflow_runs": [
        {"id": 99, "name": "build", "head_sha": "sha-old",
         "status": "completed", "conclusion": "failure"},
    ]}
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    assert out["state_value"] == "failed"
    msgs = [m for _, m in out["notify_calls"]]
    assert any("CI FAILURE" in m and "99" in m for m in msgs)


def test_conflict_detection(tmp_path):
    pr = [{
        "html_url": "u", "number": 1, "state": "open", "merged": False,
        "mergeable_state": "dirty",
    }]
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr),
    )
    assert out["state_value"] == "conflict"
    assert any("merge conflicts" in m for _, m in out["notify_calls"])


def test_behind_detection(tmp_path):
    pr = [{
        "html_url": "u", "number": 1, "state": "open", "merged": False,
        "mergeable_state": "behind",
    }]
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr),
    )
    assert out["state_value"] == "behind"
    assert any("behind the base branch" in m for _, m in out["notify_calls"])


def test_new_sha_resets_state(tmp_path):
    """A run with a new headSha resets the reported_pass/fail flags."""
    state = ci_watch.WatchState("br", "br", "old-sha", "main")
    state.reported_pass = True
    state.reported_fail = True
    state.reported_no_runs = True
    runs = [{"id": 10, "name": "build", "head_sha": "new-sha"}]
    ci_watch.detect_new_sha(state, runs)
    assert state.latest_sha == "new-sha"
    assert state.reported_pass is False
    assert state.reported_fail is False
    assert state.reported_no_runs is False


def test_health_check_failure_exits(tmp_path):
    """When health checks fail HEALTH_RETRY_MAX times, watch() returns."""
    fake_sleep, sleep_state = make_sleep_breaker(1000)

    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)), \
         patch.object(ci_watch, "_GH_TOKEN", "tk"), \
         patch.object(ci_watch.time, "sleep", fake_sleep), \
         patch.object(ci_watch, "health_check", return_value=False), \
         patch.object(ci_watch, "api_get") as mock_api, \
         patch.object(ci_watch, "notify"):
        mock_api.return_value = (None, False)
        ci_watch.watch(
            branch="b", branch_key="b", port=1, session_token="t",
            owner="o", repo="r", default_branch="main", latest_sha="s",
        )
    # Exactly HEALTH_RETRY_MAX sleeps (one per failed health attempt) before exit.
    assert sleep_state["n"] == ci_watch.HEALTH_RETRY_MAX


def test_no_runs_state(tmp_path):
    """After SHA_RUNS_EMPTY_MAX iterations of empty sha_runs, state becomes no-runs."""
    # Run has no head_sha — detect_new_sha skips update, sha_runs stays empty.
    runs = {"workflow_runs": [
        {"id": 1, "name": "build", "head_sha": None,
         "status": "in_progress", "conclusion": None},
    ]}
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] == "no-runs"
    assert any("No CI runs visible" in m for _, m in out["notify_calls"])


def test_timeout_state(tmp_path):
    """After MAIN_WAIT_MAX iterations with commit visible but no runs, state=timeout."""
    pr = [{
        "html_url": "u", "number": 1, "state": "closed", "merged": True,
        "mergeable_state": "clean", "merge_commit_sha": "merge-sha",
    }]
    # main_runs is empty — no runs match the merge SHA.
    main_runs = {"workflow_runs": []}

    fake_sleep, _ = make_sleep_breaker(ci_watch.MAIN_WAIT_MAX + 2)
    notify_calls: list[tuple[int, str]] = []
    def fake_notify(p, m):
        notify_calls.append((p, m))

    branch = "feat"
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)), \
         patch.object(ci_watch, "_GH_TOKEN", "tk-cached"), \
         patch.object(ci_watch.time, "sleep", fake_sleep), \
         patch.object(ci_watch, "api_get",
                      side_effect=make_api_get(pr=pr, main_runs=main_runs)), \
         patch.object(ci_watch, "notify", side_effect=fake_notify), \
         patch.object(ci_watch, "health_check", return_value=True), \
         patch.object(ci_watch, "has_pending_checks", return_value=False), \
         patch.object(ci_watch, "get_failed_job_names", return_value=[]), \
         patch.object(ci_watch.requests, "get") as commit_get:
        # Commit is visible on main — drives main_wait_iterations toward timeout.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch, branch_key=branch, port=1, session_token="t",
            owner="o", repo="r", default_branch="main", latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # State file must persist (keep_state_file=True).
    assert state_path.exists()
    assert state_path.read_text() == "timeout"
    assert any("No CI runs found on main" in m for _, m in notify_calls)


def test_merge_tracking(tmp_path):
    """After PR merges and main CI passes, state becomes merged-passed."""
    pr = [{
        "html_url": "u", "number": 1, "state": "closed", "merged": True,
        "mergeable_state": "clean", "merge_commit_sha": "merge-sha",
    }]
    main_runs = {"workflow_runs": [
        {"id": 50, "name": "build", "head_sha": "merge-sha",
         "status": "completed", "conclusion": "success"},
    ]}
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, main_runs=main_runs),
        max_sleeps=10,  # merge path may need a few extra ticks
    )
    assert out["state_value"] == "merged-passed"
    assert any("CI on main passed for merge" in m for _, m in out["notify_calls"])


# ---------------------------------------------------------------------------
# State writers
# ---------------------------------------------------------------------------

def test_write_state_atomic(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("br", "running")
        assert (tmp_path / "ci_watch_state_br").read_text() == "running"
        ci_watch.write_state("br", "passed")
        assert (tmp_path / "ci_watch_state_br").read_text() == "passed"


def test_write_pr_cache(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_pr_cache("br", {"url": "u", "state": "OPEN"})
        data = json.loads((tmp_path / "ci_watch_pr_br").read_text())
        assert data == {"url": "u", "state": "OPEN"}
