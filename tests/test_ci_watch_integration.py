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
        {"id": 2, "name": "test", "head_sha": "abc"},
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
        data, changed = ci_watch.api_get("https://api.github.com/x", cache, "tok")
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
        data, changed = ci_watch.api_get("https://api.github.com/x", cache, "tok")
    assert data == {"hello": "world"}
    assert changed is True
    assert cache.etag == '"new"'
    assert cache.data == {"hello": "world"}


def test_api_get_error_returns_cached():
    cache = ci_watch.ApiCache(etag='"e1"', data={"prev": True})
    with patch.object(ci_watch.requests, "get", side_effect=Exception("boom")):
        data, changed = ci_watch.api_get("https://api.github.com/x", cache, "tok")
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


def run_watch(
    tmp_dir: str,
    branch: str = "feat",
    port: int = 12345,
    token: str = "tk",
    owner: str = "o",
    repo: str = "r",
    default_branch: str = "main",
    latest_sha: str = "sha-old",
    api_get_side_effect=None,
    has_pending=False,
    health_ok=True,
    max_sleeps: int = 3,
) -> dict:
    """Drive ``ci_watch.watch`` for ``max_sleeps`` iterations.

    Returns a dict with ``notify_calls``, ``state_file_path``, ``state_value``.
    """
    fake_sleep, _ = make_sleep_breaker(max_sleeps)

    notify_calls: list[tuple[int, str]] = []

    def fake_notify(p, m):
        notify_calls.append((p, m))

    with (
        patch.object(ci_watch, "TMP_DIR", tmp_dir),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(ci_watch, "api_get", side_effect=api_get_side_effect),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "health_check", return_value=health_ok),
        patch.object(ci_watch, "has_pending_checks", return_value=has_pending),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        commit_get.return_value = MagicMock(status_code=200)
        try:
            ci_watch.watch(
                branch=branch,
                slot=branch,
                port=port,
                session_token=token,
                owner=owner,
                repo=repo,
                default_branch=default_branch,
                latest_sha=latest_sha,
            )
        except StopLoop:
            pass

    # watch() is driven with slot=branch in these tests, so the state file is
    # keyed on the bare branch string (no composite _key applied inside watch).
    state_path = Path(tmp_dir) / f"ci_watch_state_{branch}"
    raw = state_path.read_text() if state_path.exists() else None
    # New format: "<branch>:<state>:<epoch>" — value is the middle field.
    state_value = raw.split(":")[1] if raw and raw.count(":") >= 2 else raw
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
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "in_progress",
                "conclusion": None,
            },
        ]
    }
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
    # check_all_passed only fires "passed" once a PR exists with a known-good
    # mergeable_state, so the test must supply one alongside the success run.
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "clean",
        }
    ]
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "success",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, runs=runs),
        has_pending=False,
    )
    assert out["state_value"] == "passed"
    assert any("CI PASSED" in m for _, m in out["notify_calls"])


def test_ci_fails(tmp_path):
    runs = {
        "workflow_runs": [
            {
                "id": 99,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "failure",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    assert out["state_value"] == "failed"
    msgs = [m for _, m in out["notify_calls"]]
    assert any("CI FAILURE" in m and "99" in m for m in msgs)


def test_ci_passes_with_skipped_run(tmp_path):
    """Skipped workflow runs (path-filter skip) should not block 'passed'."""
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "clean",
        }
    ]
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "success",
            },
            {
                "id": 2,
                "name": "mobile-ci",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "skipped",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, runs=runs),
        has_pending=False,
    )
    assert out["state_value"] == "passed"


def test_ci_startup_failure_is_not_failure(tmp_path):
    """startup_failure conclusion should NOT trigger a CI failure notification.

    startup_failure means GitHub couldn't start the workflow (config/permission
    issue, zero jobs). It's not a code failure.
    """
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "clean",
        }
    ]
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "success",
            },
            {
                "id": 2,
                "name": "migrations",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "startup_failure",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, runs=runs),
        has_pending=False,
    )
    # Should pass, not fail — startup_failure is non-blocking.
    assert out["state_value"] == "passed"
    msgs = [m for _, m in out["notify_calls"]]
    assert not any("CI FAILURE" in m for m in msgs)
    assert any("CI PASSED" in m for m in msgs)


def test_ci_cancelled_is_not_failure(tmp_path):
    """cancelled conclusion should NOT trigger a CI failure notification.

    Cancelled runs are manually stopped — not a code failure.
    """
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "clean",
        }
    ]
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "cancelled",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, runs=runs),
        has_pending=False,
    )
    # Should pass, not fail — cancelled is non-blocking.
    assert out["state_value"] == "passed"
    msgs = [m for _, m in out["notify_calls"]]
    assert not any("CI FAILURE" in m for m in msgs)


def test_ci_real_failure(tmp_path):
    """A run with conclusion='failure' should trigger a CI FAILURE notification."""
    runs = {
        "workflow_runs": [
            {
                "id": 99,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "failure",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    assert out["state_value"] == "failed"
    msgs = [m for _, m in out["notify_calls"]]
    assert any("CI FAILURE" in m and "99" in m for m in msgs)


def test_ci_timed_out_is_failure(tmp_path):
    """A run with conclusion='timed_out' should trigger a CI FAILURE notification."""
    runs = {
        "workflow_runs": [
            {
                "id": 77,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "timed_out",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    assert out["state_value"] == "failed"
    msgs = [m for _, m in out["notify_calls"]]
    assert any("CI FAILURE" in m and "77" in m for m in msgs)


def test_conflict_detection(tmp_path):
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "dirty",
        }
    ]
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr),
    )
    assert out["state_value"] == "conflict"
    assert any("merge conflicts" in m for _, m in out["notify_calls"])


def test_behind_detection(tmp_path):
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "behind",
        }
    ]
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

    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(ci_watch, "health_check", return_value=False),
        patch.object(ci_watch, "api_get") as mock_api,
        patch.object(ci_watch, "notify"),
    ):
        mock_api.return_value = (None, False)
        ci_watch.watch(
            branch="b",
            slot="b",
            port=1,
            session_token="t",
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="s",
        )
    # Exactly HEALTH_RETRY_MAX sleeps (one per failed health attempt) before exit.
    assert sleep_state["n"] == ci_watch.HEALTH_RETRY_MAX


def test_no_runs_state(tmp_path):
    """After SHA_RUNS_EMPTY_MAX iterations of empty sha_runs, state becomes no-runs."""
    # Run has no head_sha — detect_new_sha skips update, sha_runs stays empty.
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": None,
                "status": "in_progress",
                "conclusion": None,
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] == "no-runs"
    assert any("No CI runs visible" in m for _, m in out["notify_calls"])


def test_no_ci_state(tmp_path):
    """A branch with zero workflow_runs and no PR resolves to terminal no-ci.

    After SHA_RUNS_EMPTY_MAX empty iterations, with no PR merge gate signalling
    pending required checks, the watcher writes 'no-ci' once. It must NOT fire a
    webhook — "no CI to watch" is a no-op the user finds noisy; the statusline
    flag is enough.
    """
    # Default make_api_get: pr=[] (no PR), runs={"workflow_runs": []} (zero runs).
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] == "no-ci"
    no_ci_msgs = [m for _, m in out["notify_calls"] if "no CI" in m]
    assert no_ci_msgs == [], f"expected no no-ci notify, got {no_ci_msgs}"


def test_no_ci_not_fired_when_runs_present(tmp_path):
    """A repo with workflow runs present must never be classified as no-ci."""
    runs = {
        "workflow_runs": [
            {
                "id": 1,
                "name": "build",
                "head_sha": "sha-old",
                "status": "in_progress",
                "conclusion": None,
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] != "no-ci"
    assert not any("no CI" in m for _, m in out["notify_calls"])


def test_no_ci_suppressed_when_pr_blocked(tmp_path):
    """An open PR with BLOCKED mergeable_state means required checks are pending;
    zero runs must NOT be misclassified as no-ci (CI is expected)."""
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "blocked",
        }
    ]
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] != "no-ci"
    assert not any("no CI" in m for _, m in out["notify_calls"])


def test_no_main_ci_state(tmp_path):
    """A merged PR on a repo whose default branch has NO workflow runs resolves
    to terminal no-main-ci quickly (within NO_MAIN_CI_GRACE), not a long timeout.

    Mirroring the no-CI-branch case, no webhook is fired — the statusline flag
    is enough.
    """
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "closed",
            "merged": True,
            "mergeable_state": "clean",
            "merge_commit_sha": "merge-sha",
        }
    ]
    # main_runs is empty — the default branch has no CI at all.
    main_runs = {"workflow_runs": []}

    # Allow well beyond the grace but well below MAIN_WAIT_MAX to prove it flags
    # promptly rather than burning the full timeout.
    fake_sleep, sleep_state = make_sleep_breaker(ci_watch.MAIN_WAIT_MAX)
    notify_calls: list[tuple[int, str]] = []

    def fake_notify(p, m):
        notify_calls.append((p, m))

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(
            ci_watch, "api_get", side_effect=make_api_get(pr=pr, main_runs=main_runs)
        ),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "health_check", return_value=True),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit visible on main — drives the wait counter.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            port=1,
            session_token="t",
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # State file must persist (keep_state_file=True) and read no-main-ci.
    assert state_path.exists()
    _fields = state_path.read_text().split(":")
    assert _fields[0] == branch and _fields[1] == "no-main-ci"
    assert _fields[2].isdigit()
    # Flagged at/near the grace boundary — not burning the full timeout.
    assert sleep_state["n"] <= ci_watch.NO_MAIN_CI_GRACE + 2
    # No webhook for the no-main-ci case.
    assert not any("No CI runs found on main" in m for _, m in notify_calls)


def test_transient_api_failure_does_not_flag_no_main_ci(tmp_path):
    """A persistent main-runs fetch failure (api_get returns None) during the
    merged phase must NOT be mistaken for 'no CI on main'. It falls through to
    the MAIN_WAIT_MAX timeout path and fires the actionable webhook, exactly as
    before the no-main-ci optimization."""
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "closed",
            "merged": True,
            "mergeable_state": "clean",
            "merge_commit_sha": "merge-sha",
        }
    ]

    def api_get_main_fails(url, cache, token):
        if "/pulls" in url:
            return pr, True
        if "/actions/runs" in url:
            # Simulate api_get failure with no cached data for main runs.
            if "branch=main" in url:
                return None, False
            return {"workflow_runs": []}, True
        return None, False

    fake_sleep, _ = make_sleep_breaker(ci_watch.MAIN_WAIT_MAX + 2)
    notify_calls: list[tuple[int, str]] = []

    def fake_notify(p, m):
        notify_calls.append((p, m))

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(ci_watch, "api_get", side_effect=api_get_main_fails),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "health_check", return_value=True),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit visible on main — drives main_wait_iterations toward timeout.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            port=1,
            session_token="t",
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # Must land on timeout (with webhook), NOT no-main-ci.
    _fields = state_path.read_text().split(":")
    assert _fields[0] == branch and _fields[1] == "timeout"
    assert _fields[2].isdigit()
    assert any("No CI runs found on main" in m for _, m in notify_calls)


def test_timeout_state(tmp_path):
    """After MAIN_WAIT_MAX iterations with commit visible but the merge run never
    appearing, state=timeout. Main HAS CI (a run for another commit exists), so
    this is a genuine slow/missing-run timeout, not the no-main-ci case."""
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "closed",
            "merged": True,
            "mergeable_state": "clean",
            "merge_commit_sha": "merge-sha",
        }
    ]
    # Main has CI runs, but none for the merge commit — so we wait to timeout.
    main_runs = {
        "workflow_runs": [
            {
                "id": 99,
                "name": "build",
                "head_sha": "other-sha",
                "status": "completed",
                "conclusion": "success",
            },
        ]
    }

    fake_sleep, _ = make_sleep_breaker(ci_watch.MAIN_WAIT_MAX + 2)
    notify_calls: list[tuple[int, str]] = []

    def fake_notify(p, m):
        notify_calls.append((p, m))

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(
            ci_watch, "api_get", side_effect=make_api_get(pr=pr, main_runs=main_runs)
        ),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "health_check", return_value=True),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit is visible on main — drives main_wait_iterations toward timeout.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            port=1,
            session_token="t",
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # State file must persist (keep_state_file=True).
    assert state_path.exists()
    _fields = state_path.read_text().split(":")
    assert _fields[0] == branch and _fields[1] == "timeout"
    assert _fields[2].isdigit()
    assert any("No CI runs found on main" in m for _, m in notify_calls)


def test_merge_tracking(tmp_path):
    """After PR merges and main CI passes, state becomes merged-passed."""
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "closed",
            "merged": True,
            "mergeable_state": "clean",
            "merge_commit_sha": "merge-sha",
        }
    ]
    main_runs = {
        "workflow_runs": [
            {
                "id": 50,
                "name": "build",
                "head_sha": "merge-sha",
                "status": "completed",
                "conclusion": "success",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(pr=pr, main_runs=main_runs),
        max_sleeps=10,  # merge path may need a few extra ticks
    )
    assert out["state_value"] == "merged-passed"
    assert any("CI PASSED on main" in m for _, m in out["notify_calls"])


# ---------------------------------------------------------------------------
# Merge-race false-positive prevention
# ---------------------------------------------------------------------------


def test_merge_after_behind_supersedes_behind_alert(tmp_path):
    """When 'behind' fires then merge is detected, merge notification
    includes a 'disregard' note about the previous behind alert."""
    call_count = {"n": 0}
    # Iteration 1: PR is open + behind  →  fires "CI FAILURE: behind"
    # Iteration 2: PR is merged          →  fires "PR merged (disregard)"
    pr_open_behind = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "behind",
            "merge_commit_sha": "merge-sha",
        }
    ]
    pr_merged = [
        {
            "html_url": "u",
            "number": 1,
            "state": "closed",
            "merged": True,
            "mergeable_state": "behind",
            "merge_commit_sha": "merge-sha",
        }
    ]
    runs = {"workflow_runs": []}
    main_runs = {
        "workflow_runs": [
            {
                "id": 50,
                "name": "build",
                "head_sha": "merge-sha",
                "status": "completed",
                "conclusion": "success",
            },
        ]
    }

    def side_effect(url, cache, token):
        if "/pulls" in url:
            call_count["n"] += 1
            # First two PR calls (list + single) return open/behind,
            # subsequent calls return merged.
            if call_count["n"] <= 2:
                if "/pulls/" in url:
                    return pr_open_behind[0], True
                return pr_open_behind, True
            if "/pulls/" in url:
                return pr_merged[0], True
            return pr_merged, True
        if "/actions/runs" in url:
            if "branch=main" in url:
                return main_runs, True
            return runs, True
        return None, False

    out = run_watch(
        str(tmp_path),
        api_get_side_effect=side_effect,
        max_sleeps=10,
    )
    msgs = [m for _, m in out["notify_calls"]]
    # The merge notification should include the superseded note.
    merge_msgs = [m for m in msgs if "merged" in m.lower()]
    assert any("disregard" in m for m in merge_msgs), (
        f"Expected 'disregard' in merge notification, got: {merge_msgs}"
    )
    assert any("behind" in m for m in merge_msgs), (
        f"Expected 'behind' mentioned in merge notification, got: {merge_msgs}"
    )


def test_failure_suppressed_when_pr_fetch_fails(tmp_path):
    """When the PR list endpoint returns None (API timeout with no cached
    data), branch failure notifications are suppressed.

    This simulates a scenario where a watcher starts, the PR endpoint
    times out (returning None), runs show failures, but since we can't
    confirm the PR is still open (it might already be merged), we
    suppress the failure notification.
    """
    runs_with_failure = {
        "workflow_runs": [
            {
                "id": 99,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "failure",
            },
        ]
    }

    def side_effect(url, cache, token):
        if "/pulls" in url:
            # PR endpoint always fails — returns None (no cached data).
            return None, False
        if "/actions/runs" in url:
            return runs_with_failure, True
        return None, False

    out = run_watch(
        str(tmp_path),
        api_get_side_effect=side_effect,
        max_sleeps=3,
    )
    msgs = [m for _, m in out["notify_calls"]]
    # No CI FAILURE notification should fire — PR data is unavailable
    # and we can't confirm the PR is still open.
    fail_msgs = [m for m in msgs if "CI FAILURE" in m]
    assert fail_msgs == [], (
        f"Expected no CI FAILURE when PR fetch failed, got: {fail_msgs}"
    )


def test_failure_still_fires_without_pr(tmp_path):
    """When no PR exists at all (branch without PR), failures still fire."""
    runs = {
        "workflow_runs": [
            {
                "id": 99,
                "name": "build",
                "head_sha": "sha-old",
                "status": "completed",
                "conclusion": "failure",
            },
        ]
    }
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(runs=runs),
    )
    assert out["state_value"] == "failed"
    msgs = [m for _, m in out["notify_calls"]]
    assert any("CI FAILURE" in m for m in msgs)


# ---------------------------------------------------------------------------
# State writers
# ---------------------------------------------------------------------------


def test_write_state_atomic(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("br", "br", "running")
        fields = (tmp_path / "ci_watch_state_br").read_text().split(":")
        assert fields[0] == "br" and fields[1] == "running" and fields[2].isdigit()
        ci_watch.write_state("br", "br", "passed")
        fields = (tmp_path / "ci_watch_state_br").read_text().split(":")
        assert fields[0] == "br" and fields[1] == "passed" and fields[2].isdigit()


def test_write_pr_cache(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_pr_cache("br", {"url": "u", "state": "OPEN"})
        data = json.loads((tmp_path / "ci_watch_pr_br").read_text())
        assert data == {"url": "u", "state": "OPEN"}


# ---------------------------------------------------------------------------
# Composite key + sanitize_branch
# ---------------------------------------------------------------------------


def test_sanitize_branch_hash_suffix():
    out = ci_watch.sanitize_branch("feature/foo")
    # readable prefix keeps safe chars, slashes become dashes, then -<hash8>.
    assert out.startswith("feature-foo-")
    suffix = out.rsplit("-", 1)[1]
    assert len(suffix) == 8 and all(c in "0123456789abcdef" for c in suffix)


def test_sanitize_branch_collision_resistance():
    """'feature/foo' and 'feature-foo' must NOT share a key (lossy char-replace
    would collide them; the sha256 suffix is the guarantor)."""
    a = ci_watch.sanitize_branch("feature/foo")
    b = ci_watch.sanitize_branch("feature-foo")
    # Same readable prefix, different hash → different full key.
    assert a != b
    assert a.rsplit("-", 1)[0] == b.rsplit("-", 1)[0]


def test_key_composite_scheme():
    key = ci_watch._key("sess-uuid", "feature/foo")
    assert key == f"sess-uuid__{ci_watch.sanitize_branch('feature/foo')}"
    assert "__" in key


def test_temp_files_not_matching_status_glob(tmp_path):
    """mkstemp temp files must use a neutral prefix so status_line's
    ci_watch_state_<key>* glob never matches an in-flight temp file."""
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("slot__br-abc", "br", "running")
        ci_watch.write_pr_cache("slot__br-abc", {"url": "u"})
    names = [p.name for p in tmp_path.iterdir()]
    # Exactly the two final files; no leftover temp files, and none of the
    # temp prefixes collide with the state/pr key prefixes.
    assert "ci_watch_state_slot__br-abc" in names
    assert "ci_watch_pr_slot__br-abc" in names
    assert not any(n.startswith("ci_watch_tmp_") for n in names)


# ---------------------------------------------------------------------------
# Epoch (F2) — timer semantics of write_state
# ---------------------------------------------------------------------------


def _read_epoch(path: Path) -> int:
    return int(path.read_text().split(":")[2])


def test_epoch_preserved_across_same_value_writes(tmp_path):
    """Repeated same-value writes (e.g. every-iteration 'merging') keep the
    first epoch so the timer keeps ticking."""
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        with patch.object(ci_watch.time, "time", return_value=1000):
            ci_watch.write_state("k", "br", "merging")
        path = tmp_path / "ci_watch_state_k"
        assert _read_epoch(path) == 1000
        with patch.object(ci_watch.time, "time", return_value=1050):
            ci_watch.write_state("k", "br", "merging")
        assert _read_epoch(path) == 1000  # preserved


def test_epoch_resets_on_value_change(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        with patch.object(ci_watch.time, "time", return_value=1000):
            ci_watch.write_state("k", "br", "running")
        path = tmp_path / "ci_watch_state_k"
        assert _read_epoch(path) == 1000
        with patch.object(ci_watch.time, "time", return_value=1050):
            ci_watch.write_state("k", "br", "passed")
        assert _read_epoch(path) == 1050  # reset on transition


def test_epoch_resets_on_reset_timer_even_same_value(tmp_path):
    """A new-SHA / rerun writes 'running' when the value is already 'running';
    reset_timer=True must still restart the timer."""
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        with patch.object(ci_watch.time, "time", return_value=1000):
            ci_watch.write_state("k", "br", "running")
        path = tmp_path / "ci_watch_state_k"
        assert _read_epoch(path) == 1000
        with patch.object(ci_watch.time, "time", return_value=1050):
            ci_watch.write_state("k", "br", "running", reset_timer=True)
        assert _read_epoch(path) == 1050


def test_epoch_fresh_when_legacy_two_field_file(tmp_path):
    """A legacy 2-field file (no epoch) is treated as 'no valid epoch' → now."""
    path = tmp_path / "ci_watch_state_k"
    path.write_text("br:running")  # legacy 2-field
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        with patch.object(ci_watch.time, "time", return_value=2000):
            ci_watch.write_state("k", "br", "running")
    assert _read_epoch(path) == 2000


# ---------------------------------------------------------------------------
# Per-branch lock eviction (F1)
# ---------------------------------------------------------------------------


def test_acquire_lock_is_per_branch(tmp_path):
    """acquire_lock for branch-A's key must not touch branch-B's lock file."""
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        key_a = ci_watch._key("sess", "feat-a")
        key_b = ci_watch._key("sess", "feat-b")
        # Pre-seed B's lock with a live-but-unrelated PID (this test process).
        ci_watch._lock_path(key_b).write_text(str(os.getpid()))
        b_before = ci_watch._lock_path(key_b).read_text()
        ci_watch.acquire_lock(key_a)
        # A's lock now holds our pid; B's lock is untouched.
        assert ci_watch._lock_path(key_a).read_text() == str(os.getpid())
        assert ci_watch._lock_path(key_b).read_text() == b_before


def test_main_aborts_without_session_id(monkeypatch, capsys):
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    monkeypatch.setattr(sys, "argv", ["ci_watch.py", "br", "1234", "tok"])
    with pytest.raises(SystemExit) as exc:
        ci_watch.main()
    assert exc.value.code == 2
    assert "CLAUDE_CODE_SESSION_ID" in capsys.readouterr().err
