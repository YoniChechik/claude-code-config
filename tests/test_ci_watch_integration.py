# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "requests>=2.31",
#   "pytest>=8",
# ]
# ///
"""Integration tests for ci_watch.

Tests import the ci_watch module directly. The module's network calls
(``api_get``) and its stdout notification sink (``notify``) are mocked, and
``time.sleep`` is patched to break the watch loop after a controlled number of
iterations.
"""

from __future__ import annotations

import ast
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

# Make the ci-watcher skill dir importable.
SCRIPTS_DIR = Path(__file__).parent.parent / "skills" / "ci-watcher"
sys.path.insert(0, str(SCRIPTS_DIR))

import ci_watch


@pytest.fixture(autouse=True)
def _reset_monitor_detached_state():
    """The monitor-detached marker is sticky for the process lifetime by design.

    That is right for a watcher and wrong for a test session: one test tripping
    a broken stdout would otherwise append the marker to every later test's
    state file. Reset both module globals around each test.
    """
    ci_watch._MONITOR_DETACHED_AT = None
    ci_watch._LAST_STATE = None
    yield
    ci_watch._MONITOR_DETACHED_AT = None
    ci_watch._LAST_STATE = None


def _drop_lock_fd():
    if ci_watch._LOCK_FD is not None:
        try:
            os.close(ci_watch._LOCK_FD)
        except OSError:
            pass
    ci_watch._LOCK_FD = None
    ci_watch._LOCK_SLOT = None


@pytest.fixture(autouse=True)
def _reset_lock_state():
    """``acquire_lock`` keeps its flock fd for the life of the process by design.

    That is right for a watcher and wrong for a test session: one test taking
    the lock for real would hold it for every later test, and the fd would leak.
    Drop the fd and both module globals around each test.
    """
    _drop_lock_fd()
    yield
    _drop_lock_fd()


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
    owner: str = "o",
    repo: str = "r",
    default_branch: str = "main",
    latest_sha: str = "sha-old",
    api_get_side_effect=None,
    has_pending=False,
    max_sleeps: int = 3,
    strict_policy: bool = False,
    real_notify: bool = False,
    no_ci_configured: bool = False,
) -> dict:
    """Drive ``ci_watch.watch`` for ``max_sleeps`` iterations.

    Returns a dict with ``notify_calls`` and ``state_value``.

    ``strict_policy`` stubs ``get_strict_required_status_checks_policy`` so
    tests never shell out to the real ``gh`` CLI; it defaults to False (the
    function's own fail-safe default) and is overridden to True by tests
    that exercise the "behind" alert.

    ``real_notify`` keeps recording every message BUT also lets the real
    ``notify`` run, so a caller holding ``capsys`` can compare the recorded
    messages against what actually reached stdout.

    ``no_ci_configured`` stubs the one-shot ``detect_no_ci_configured`` probe so
    tests never hit the real workflows/contents endpoints; it defaults to False
    (a repo that DOES have workflow files), the normal case.
    """
    fake_sleep, _ = make_sleep_breaker(max_sleeps)

    notify_calls: list[str] = []
    unpatched_notify = ci_watch.notify

    def fake_notify(m):
        notify_calls.append(m)
        if real_notify:
            unpatched_notify(m)

    with (
        patch.object(ci_watch, "TMP_DIR", tmp_dir),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(ci_watch, "api_get", side_effect=api_get_side_effect),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "has_pending_checks", return_value=has_pending),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(
            ci_watch,
            "get_strict_required_status_checks_policy",
            return_value=strict_policy,
        ),
        patch.object(
            ci_watch, "detect_no_ci_configured", return_value=no_ci_configured
        ),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        commit_get.return_value = MagicMock(status_code=200)
        try:
            ci_watch.watch(
                branch=branch,
                slot=branch,
                owner=owner,
                repo=repo,
                default_branch=default_branch,
                latest_sha=latest_sha,
            )
        except StopLoop:
            pass

    state_path = Path(tmp_dir) / f"ci_watch_state_{branch}"
    raw = state_path.read_text() if state_path.exists() else None
    state_value = raw.split(":", 1)[1] if raw and ":" in raw else raw
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
    # No pass/fail notification fired; state stays 'running'.
    pass_msgs = [m for m in out["notify_calls"] if "passed" in m.lower()]
    fail_msgs = [m for m in out["notify_calls"] if "failure" in m.lower()]
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
    assert any("CI PASSED" in m for m in out["notify_calls"])


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
    msgs = out["notify_calls"]
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
    msgs = out["notify_calls"]
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
    msgs = out["notify_calls"]
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
    msgs = out["notify_calls"]
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
    assert any("merge conflicts" in m for m in out["notify_calls"])


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
        strict_policy=True,
    )
    assert out["state_value"] == "behind"
    assert any("behind the base branch" in m for m in out["notify_calls"])


def test_behind_not_reported_when_not_strict(tmp_path):
    """When the repo's branch protection doesn't require branches to be up
    to date before merging, mergeable_state=behind must NOT fire — GitHub
    will merge it fine, so alerting would be a false positive."""
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
        strict_policy=False,
    )
    assert out["state_value"] != "behind"
    assert not any("behind the base branch" in m for m in out["notify_calls"])


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
    assert any("No CI runs visible" in m for m in out["notify_calls"])


def test_no_ci_state(tmp_path):
    """A branch with zero workflow_runs and no PR resolves to terminal no-ci.

    After SHA_RUNS_EMPTY_MAX empty iterations, with no PR merge gate signalling
    pending required checks, the watcher writes 'no-ci' once. It must NOT fire a
    notification — "no CI to watch" is a no-op the user finds noisy; the statusline
    flag is enough.
    """
    # Default make_api_get: pr=[] (no PR), runs={"workflow_runs": []} (zero runs).
    out = run_watch(
        str(tmp_path),
        api_get_side_effect=make_api_get(),
        max_sleeps=ci_watch.SHA_RUNS_EMPTY_MAX + 2,
    )
    assert out["state_value"] == "no-ci"
    no_ci_msgs = [m for m in out["notify_calls"] if "no CI" in m]
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
    assert not any("no CI" in m for m in out["notify_calls"])


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
    assert not any("no CI" in m for m in out["notify_calls"])


# ---------------------------------------------------------------------------
# "no CI configured at all" detection (zero workflow files in the repo)
# ---------------------------------------------------------------------------


def _fake_resp(status: int, payload: Any = None) -> MagicMock:
    resp = MagicMock(status_code=status)
    resp.json.return_value = payload
    return resp


@pytest.mark.parametrize(
    ("status", "payload", "expected"),
    [
        (200, {"total_count": 0, "workflows": []}, 0),
        (200, {"total_count": 3, "workflows": []}, 3),
        (200, {"workflows": []}, None),  # no total_count -> unknown
        (200, ["not", "a", "dict"], None),
        (403, {"message": "rate limited"}, None),
        (500, None, None),
    ],
)
def test_count_repo_workflows(status, payload, expected):
    with patch.object(
        ci_watch.requests, "get", return_value=_fake_resp(status, payload)
    ):
        assert ci_watch.count_repo_workflows("o", "r", "tk") == expected


def test_count_repo_workflows_network_error_is_unknown():
    with patch.object(ci_watch.requests, "get", side_effect=OSError("boom")):
        assert ci_watch.count_repo_workflows("o", "r", "tk") is None


@pytest.mark.parametrize(
    ("status", "payload", "expected"),
    [
        (404, {"message": "Not Found"}, False),  # no .github/workflows dir
        (200, [{"type": "file", "name": "ci.yml"}], True),
        (200, [{"type": "file", "name": "ci.yaml"}], True),
        (200, [], False),  # empty dir
        (200, [{"type": "file", "name": "README.md"}], False),
        (200, [{"type": "dir", "name": "nested"}], False),
        (200, {"type": "file", "name": "workflows"}, None),  # unexpected shape
        (500, None, None),
    ],
)
def test_ref_has_workflow_files(status, payload, expected):
    with patch.object(
        ci_watch.requests, "get", return_value=_fake_resp(status, payload)
    ):
        assert ci_watch.ref_has_workflow_files("o", "r", "feat", "tk") is expected


@pytest.mark.parametrize(
    ("total", "branch_files", "main_files", "expected"),
    [
        # Only case that claims no-CI: zero registered workflows AND no workflow
        # file on either ref.
        (0, False, False, True),
        # Repo has workflows registered -> a run can appear; keep waiting.
        (2, False, False, False),
        # PR that INTRODUCES the first workflow: head ref has the file, so its
        # own checks will run.
        (0, True, False, False),
        # Default branch has one (e.g. head ref deletes it) -> main CI can run.
        (0, False, True, False),
        # Unknown signals always fail toward "keep waiting".
        (None, False, False, False),
        (0, None, False, False),
        (0, False, None, False),
    ],
)
def test_detect_no_ci_configured(total, branch_files, main_files, expected):
    per_ref = {"feat": branch_files, "main": main_files}
    with (
        patch.object(ci_watch, "count_repo_workflows", return_value=total),
        patch.object(
            ci_watch,
            "ref_has_workflow_files",
            side_effect=lambda o, r, ref, tk: per_ref[ref],
        ),
    ):
        assert (
            ci_watch.detect_no_ci_configured("o", "r", "feat", "main", "tk") is expected
        )


def test_detect_no_ci_configured_checks_each_ref_once():
    """The probe must not re-query the same ref twice when branch == default."""
    calls: list[str] = []

    def record(_o, _r, ref, _tk):
        calls.append(ref)
        return False

    with (
        patch.object(ci_watch, "count_repo_workflows", return_value=0),
        patch.object(ci_watch, "ref_has_workflow_files", side_effect=record),
    ):
        assert ci_watch.detect_no_ci_configured("o", "r", "main", "main", "tk") is True
    assert calls == ["main"]


def test_no_ci_configured_flags_immediately_and_skips_branch_polling(tmp_path):
    """Zero workflow files -> 'no-ci-configured' on the first iteration.

    Even with an open PR whose mergeable_state is BLOCKED (which normally means
    "required checks pending, keep waiting"), there is nothing to wait for: the
    runs endpoint must never be polled and the 2-min no-runs grace must never
    be entered.
    """
    pr = [
        {
            "html_url": "u",
            "number": 1,
            "state": "open",
            "merged": False,
            "mergeable_state": "blocked",
        }
    ]
    urls: list[str] = []
    routed = make_api_get(pr=pr)

    def recording(url, cache, token):
        urls.append(url)
        return routed(url, cache, token)

    out = run_watch(
        str(tmp_path),
        api_get_side_effect=recording,
        no_ci_configured=True,
        max_sleeps=3,
    )
    assert out["state_value"] == "no-ci-configured"
    assert any("No CI configured" in m for m in out["notify_calls"])
    assert not any("/actions/runs" in u for u in urls)


def test_no_ci_configured_exits_on_merge_without_waiting_for_main_ci(tmp_path):
    """A merge in a repo with no workflow files ends the watch immediately.

    The merge itself is still reported (that is the useful signal), but the
    main-CI phase — NO_MAIN_CI_GRACE and the 5-min MAIN_WAIT_MAX — is skipped
    entirely, so the default-branch runs endpoint is never polled.
    """
    pr = [
        {
            "html_url": "u",
            "number": 7,
            "state": "closed",
            "merged": True,
            "mergeable_state": "clean",
            "merge_commit_sha": "merge-sha",
        }
    ]
    urls: list[str] = []
    routed = make_api_get(pr=pr)

    def recording(url, cache, token):
        urls.append(url)
        return routed(url, cache, token)

    out = run_watch(
        str(tmp_path),
        api_get_side_effect=recording,
        no_ci_configured=True,
        max_sleeps=ci_watch.MAIN_WAIT_MAX,
    )
    assert out["state_value"] == "no-ci-configured"
    assert any("merged to main" in m for m in out["notify_calls"])
    assert not any("branch=main" in u for u in urls)


def test_no_main_ci_state(tmp_path):
    """A merged PR on a repo whose default branch has NO workflow runs resolves
    to terminal no-main-ci quickly (within NO_MAIN_CI_GRACE), not a long timeout.

    Mirroring the no-CI-branch case, no notification is fired — the statusline flag
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
    notify_calls: list[str] = []

    def fake_notify(m):
        notify_calls.append(m)

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(
            ci_watch, "api_get", side_effect=make_api_get(pr=pr, main_runs=main_runs)
        ),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit visible on main — drives the wait counter.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # State file must persist (keep_state_file=True) and read no-main-ci.
    assert state_path.exists()
    assert state_path.read_text() == f"{branch}:no-main-ci"
    # Flagged at/near the grace boundary — not burning the full timeout.
    assert sleep_state["n"] <= ci_watch.NO_MAIN_CI_GRACE + 2
    # No notification for the no-main-ci case.
    assert not any("No CI runs found on main" in m for m in notify_calls)


def test_transient_api_failure_does_not_flag_no_main_ci(tmp_path):
    """A persistent main-runs fetch failure (api_get returns None) during the
    merged phase must NOT be mistaken for 'no CI on main'. It falls through to
    the MAIN_WAIT_MAX timeout path and fires the actionable notification, exactly as
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
    notify_calls: list[str] = []

    def fake_notify(m):
        notify_calls.append(m)

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(ci_watch, "api_get", side_effect=api_get_main_fails),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit visible on main — drives main_wait_iterations toward timeout.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # Must land on timeout (with notification), NOT no-main-ci.
    assert state_path.read_text() == f"{branch}:timeout"
    assert any("No CI runs found on main" in m for m in notify_calls)


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
    notify_calls: list[str] = []

    def fake_notify(m):
        notify_calls.append(m)

    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(
            ci_watch, "api_get", side_effect=make_api_get(pr=pr, main_runs=main_runs)
        ),
        patch.object(ci_watch, "notify", side_effect=fake_notify),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        # Commit is visible on main — drives main_wait_iterations toward timeout.
        commit_get.return_value = MagicMock(status_code=200)
        ci_watch.watch(
            branch=branch,
            slot=branch,
            owner="o",
            repo="r",
            default_branch="main",
            latest_sha="sha-old",
        )

    state_path = Path(str(tmp_path)) / f"ci_watch_state_{branch}"
    # State file must persist (keep_state_file=True).
    assert state_path.exists()
    assert state_path.read_text() == f"{branch}:timeout"
    assert any("No CI runs found on main" in m for m in notify_calls)


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
    assert any("CI PASSED on main" in m for m in out["notify_calls"])


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
        strict_policy=True,
    )
    msgs = out["notify_calls"]
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
    msgs = out["notify_calls"]
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
    msgs = out["notify_calls"]
    assert any("CI FAILURE" in m for m in msgs)


# ---------------------------------------------------------------------------
# State writers
# ---------------------------------------------------------------------------


def test_write_state_atomic(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("br", "br", "running")
        assert (tmp_path / "ci_watch_state_br").read_text() == "br:running"
        ci_watch.write_state("br", "br", "passed")
        assert (tmp_path / "ci_watch_state_br").read_text() == "br:passed"


def test_write_pr_cache(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_pr_cache("br", {"url": "u", "state": "OPEN"})
        data = json.loads((tmp_path / "ci_watch_pr_br").read_text())
        assert data == {"url": "u", "state": "OPEN"}


def test_notify_writes_one_stdout_line(capsys):
    ci_watch.notify("CI PASSED on branch x")
    captured = capsys.readouterr()
    assert captured.out == "CI PASSED on branch x\n"
    assert captured.err == ""


def test_stdout_carries_only_notifications(tmp_path, capsys):
    """Monitor treats every stdout line as a session notification and auto-stops
    a monitor that emits too many. Drive the merged path with the REAL notify and
    assert stdout holds notifications only — no write_state / heartbeat / banner.
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
    # A still-running main run for the merge commit keeps the loop iterating
    # without firing a terminal pass/fail notification.
    main_runs = {
        "workflow_runs": [
            {
                "id": 7,
                "name": "build",
                "head_sha": "merge-sha",
                "status": "in_progress",
                "conclusion": None,
            },
        ]
    }

    fake_sleep, _ = make_sleep_breaker(5)
    branch = "feat"
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch, "_GH_TOKEN", "tk-cached"),
        patch.object(ci_watch.time, "sleep", fake_sleep),
        patch.object(
            ci_watch, "api_get", side_effect=make_api_get(pr=pr, main_runs=main_runs)
        ),
        patch.object(ci_watch, "has_pending_checks", return_value=False),
        patch.object(ci_watch, "get_failed_job_names", return_value=[]),
        patch.object(ci_watch.requests, "get") as commit_get,
    ):
        commit_get.return_value = MagicMock(status_code=200)
        try:
            ci_watch.watch(
                branch=branch,
                slot=branch,
                owner="o",
                repo="r",
                default_branch="main",
                latest_sha="sha-old",
            )
        except StopLoop:
            pass

    captured = capsys.readouterr()
    stdout_lines = [ln for ln in captured.out.splitlines() if ln]
    assert stdout_lines == ["PR #1 merged to main"]
    # The diagnostics DID run — they just went to stderr.
    assert "[ci_watch] write_state" in captured.err
    assert "[ci_watch] starting watch loop" in captured.err


def test_notify_multiline_message_is_written_whole_and_flushed():
    """A multi-line notification must reach stdout as ONE ``print`` of the whole
    body plus a single trailing newline, followed by a flush.

    Monitor batches stdout lines that arrive within 200ms into one
    notification. Rewriting ``notify`` to loop over the lines (one ``print``
    per line) would put every line at the mercy of that timing window and can
    split one alert into many notifications, so the body must never be split.
    The flush is what stops a finished notification from sitting in a block
    buffer until the next one (or being lost entirely on SIGKILL).
    """
    events: list[tuple[str, str]] = []

    class RecordingStdout:
        def write(self, s: str) -> int:
            events.append(("write", s))
            return len(s)

        def flush(self) -> None:
            events.append(("flush", ""))

    msg = "CI FAILURE on branch feat: STUCK\nline two\n\nline four"
    with patch.object(ci_watch.sys, "stdout", RecordingStdout()):
        ci_watch.notify(msg)

    writes = [payload for kind, payload in events if kind == "write"]
    # print() emits the body, then the terminator — the body itself must be
    # one single write, never one write per line.
    assert writes[0] == msg
    assert "".join(writes) == msg + "\n"
    # The flush must come after the whole message, not before or between writes.
    assert events[-1][0] == "flush"


def test_notify_survives_a_dead_stdout():
    """A broken pipe must never kill the watcher.

    Monitor auto-stops a task that emits too many events, and the skill's
    CRITICAL RULE is that nothing stops this process by accident. So a failed
    write is dropped with a stderr warning instead of propagating.
    """

    class BrokenStdout:
        def write(self, s: str) -> int:
            raise BrokenPipeError(32, "Broken pipe")

        def flush(self) -> None:
            pass

    with patch.object(ci_watch.sys, "stdout", BrokenStdout()):
        ci_watch.notify("CI PASSED on branch feat")  # must not raise


def test_notify_records_a_dead_channel_in_the_state_file(tmp_path):
    """A dropped notification must leave a durable trace.

    Without it, "watcher alive and reporting" and "watcher alive but every
    notification is going nowhere" look identical to the pid-liveness check that
    SKILL.md, ci_is_active and status_line.sh all rely on.
    """

    class BrokenStdout:
        def write(self, s: str) -> int:
            raise BrokenPipeError(32, "Broken pipe")

        def flush(self) -> None:
            pass

    state_file = tmp_path / "ci_watch_state_slot-1"
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("slot-1", "feat", "running")
        assert state_file.read_text() == "feat:running"

        with patch.object(ci_watch.sys, "stdout", BrokenStdout()):
            ci_watch.notify("CI PASSED on branch feat")

        marked = state_file.read_text()
        assert marked.startswith("feat:running:monitor-detached@")
        assert int(marked.rsplit("@", 1)[1]) > 0

        # Sticky: a later state write keeps carrying the marker, and a stdout
        # write that happens to succeed does NOT clear it.
        ci_watch.notify("CI PASSED on branch feat")
        ci_watch.write_state("slot-1", "feat", "passed")
        assert state_file.read_text().startswith("feat:passed:monitor-detached@")


def test_notify_survives_stdout_and_stderr_dying_together(tmp_path):
    """Monitor's auto-detach closes BOTH pipes, not just stdout.

    The stderr warning inside the failed-stdout handler would then raise a
    second OSError out of ``notify`` and kill the watcher — the exact death the
    handler exists to prevent. The marker must still land on disk.
    """

    class BrokenStream:
        def write(self, s: str) -> int:
            raise BrokenPipeError(32, "Broken pipe")

        def flush(self) -> None:
            raise BrokenPipeError(32, "Broken pipe")

    state_file = tmp_path / "ci_watch_state_slot-1"
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        ci_watch.write_state("slot-1", "feat", "running")

        with (
            patch.object(ci_watch.sys, "stdout", BrokenStream()),
            patch.object(ci_watch.sys, "stderr", BrokenStream()),
        ):
            ci_watch.notify("CI PASSED on branch feat")  # must not raise

        assert state_file.read_text().startswith("feat:running:monitor-detached@")


def test_stuck_pending_multiline_notification_reaches_stdout_intact(tmp_path, capsys):
    """The longest notification the watcher emits (STUCK_PENDING_REQUIRED_CHECKS,
    ~20 lines) must land on stdout byte-for-byte, with the diagnostics that the
    same call path writes going to stderr.
    """
    state = ci_watch.WatchState("feat", "feat", "sha-old", "main")
    stuck = frozenset({"build / test", "lint"})
    state.stuck_pending_names = stuck
    state.stuck_pending_iters = ci_watch.STUCK_PENDING_MIN_ITERS - 1

    # detect_stuck_pending shells out to `gh` (external service) — the only
    # thing stubbed here; the message building and notify path are real.
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(
            ci_watch, "detect_stuck_pending", return_value=(stuck, 4242, True)
        ),
    ):
        ci_watch.check_stuck_pending(state, "o", "r", "main", 7)

    expected = ci_watch._stuck_pending_message("feat", "o", "r", stuck, 4242)
    captured = capsys.readouterr()
    assert captured.out == expected + "\n"
    assert len(expected.splitlines()) > 10, "message should be genuinely multi-line"
    # ``expected`` comes from the same function under test, so it only pins the
    # plumbing. Assert the load-bearing content separately: without the check
    # names and the ruleset id the alert is not actionable.
    for name in stuck:
        assert name in captured.out
    assert "4242" in captured.out
    assert "feat" in captured.out
    # The state write happened, and its log line went to stderr only.
    assert (tmp_path / "ci_watch_state_feat").read_text() == "feat:stuck-pending"
    assert "[ci_watch] write_state" in captured.err
    assert state.reported_stuck_pending is True


def test_every_print_outside_notify_targets_stderr():
    """Static guard on the Monitor contract: stdout is the notification stream,
    so ``notify`` owns the ONLY ``print`` in ci_watch.py without
    ``file=sys.stderr``. A new diagnostic print that forgets the kwarg would
    turn into a spurious session notification.
    """
    tree = ast.parse((SCRIPTS_DIR / "ci_watch.py").read_text())
    notify_fn = next(
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef) and n.name == "notify"
    )
    inside_notify = {id(n) for n in ast.walk(notify_fn)}

    offenders = []
    for node in ast.walk(tree):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "print"
        ):
            continue
        if id(node) in inside_notify:
            continue
        file_kw = next((k for k in node.keywords if k.arg == "file"), None)
        if file_kw is None or ast.unparse(file_kw.value) != "sys.stderr":
            offenders.append(node.lineno)
    assert offenders == [], (
        f"print() without file=sys.stderr at ci_watch.py lines {offenders} — "
        "stdout is reserved for notify()"
    )

    # print() is not the only way onto stdout. ``os.write`` is legitimate on a
    # descriptor of our own (acquire_lock stamps its pid into the lock fd that
    # way), so it counts as an offender only when the target could be stdout:
    # the literal fd 1, or any name that mentions stdout.
    def _targets_stdout(node: ast.Call) -> bool:
        func = ast.unparse(node.func)
        if func == "sys.stdout.write":
            return True
        if func != "os.write":
            return False
        target = ast.unparse(node.args[0]) if node.args else ""
        return target == "1" or "stdout" in target

    direct_writes = [
        node.lineno
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and id(node) not in inside_notify
        and _targets_stdout(node)
    ]
    assert direct_writes == [], (
        f"direct stdout write at ci_watch.py lines {direct_writes} — "
        "stdout is reserved for notify()"
    )


def test_every_subprocess_call_captures_its_child_stdout():
    """A child process that inherits stdout writes straight into the Monitor
    event stream. Every ``gh``/``git`` shell-out must capture or redirect it.
    """
    tree = ast.parse((SCRIPTS_DIR / "ci_watch.py").read_text())
    offenders = []
    for node in ast.walk(tree):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr in ("run", "Popen", "call", "check_call")
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "subprocess"
        ):
            continue
        kwargs = {k.arg for k in node.keywords}
        if not kwargs & {"capture_output", "stdout"}:
            offenders.append(node.lineno)
    assert offenders == [], (
        f"subprocess call inheriting stdout at ci_watch.py lines {offenders} — "
        "pass capture_output=True or an explicit stdout="
    )


@pytest.mark.parametrize(
    "scenario",
    ["running", "branch_failure", "pr_closed_without_merge", "no_runs"],
)
def test_stdout_equals_the_notifications_for(scenario, tmp_path, capsys):
    """Whatever the watcher does, stdout must equal exactly the notifications it
    emitted — nothing more (diagnostics leaking) and nothing less (a message
    swallowed). Covers the non-merged terminal paths that
    ``test_stdout_carries_only_notifications`` does not reach.
    """
    open_pr = {
        "html_url": "u",
        "number": 1,
        "state": "open",
        "merged": False,
        "mergeable_state": "clean",
        "merge_commit_sha": None,
    }
    kwargs: dict[str, Any]
    if scenario == "running":
        kwargs = {
            "api_get_side_effect": make_api_get(
                runs={
                    "workflow_runs": [
                        {
                            "id": 1,
                            "name": "build",
                            "head_sha": "sha-old",
                            "status": "in_progress",
                            "conclusion": None,
                        }
                    ]
                }
            ),
            "max_sleeps": 3,
        }
    elif scenario == "branch_failure":
        kwargs = {
            "api_get_side_effect": make_api_get(
                pr=[open_pr],
                runs={
                    "workflow_runs": [
                        {
                            "id": 99,
                            "name": "build",
                            "head_sha": "sha-old",
                            "status": "completed",
                            "conclusion": "failure",
                        }
                    ]
                },
            ),
            "max_sleeps": 3,
        }
    elif scenario == "pr_closed_without_merge":
        kwargs = {
            "api_get_side_effect": make_api_get(
                pr=[{**open_pr, "state": "closed", "merged": False}]
            ),
            "max_sleeps": 3,
        }
    else:  # no_runs — SHA_RUNS_EMPTY_MAX iterations with an empty run list
        kwargs = {
            "api_get_side_effect": make_api_get(
                pr=[open_pr],
                runs={
                    "workflow_runs": [
                        {
                            "id": 1,
                            "name": "build",
                            "status": "completed",
                            "conclusion": "success",
                        }
                    ]
                },
            ),
            "max_sleeps": ci_watch.SHA_RUNS_EMPTY_MAX + 2,
        }

    out = run_watch(str(tmp_path), real_notify=True, **kwargs)

    captured = capsys.readouterr()
    assert captured.out == "".join(m + "\n" for m in out["notify_calls"])
    assert "[ci_watch]" not in captured.out
    if scenario == "running":
        assert captured.out == ""
    else:
        assert out["notify_calls"], f"{scenario} should emit a notification"


def _acquire_lock_against_predecessor(
    tmp_path, dies_on: int | None, pid_recycled: bool = False
) -> dict:
    """Run ``acquire_lock`` against a fake live predecessor.

    The fake holds a REAL ``flock`` on the real lockfile, taken on its own file
    descriptor, so ``acquire_lock`` meets the same kernel refusal a second
    watcher process would. ``dies_on`` is the signal number that makes the fake
    exit (None = it survives everything); dying drops its flock, exactly as the
    kernel does when a process goes away. ``pid_recycled`` makes every ``ps``
    lookup after the first one report an unrelated process on that pid.

    Returns {"sent": signals sent, "lock": lockfile text, "code": exit code}.
    """
    old_pid = os.getpid() + 12345
    sent: list[int] = []
    alive = {"v": True}

    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        # Inside the patch: _lock_path reads TMP_DIR at call time.
        lock = Path(ci_watch._lock_path("slot-1"))
        holder_fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(holder_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.write(holder_fd, str(old_pid).encode())

            def fake_kill(pid: int, sig: int) -> None:
                assert pid == old_pid
                if sig == 0:
                    if alive["v"]:
                        return
                    raise ProcessLookupError
                sent.append(sig)
                if sig == dies_on:
                    alive["v"] = False
                    fcntl.flock(holder_fd, fcntl.LOCK_UN)

            ps_calls = {"n": 0}

            def fake_ps(*args, **kwargs):
                ps_calls["n"] += 1
                if pid_recycled and ps_calls["n"] > 1:
                    return MagicMock(stdout="/usr/bin/some-unrelated-process\n")
                return MagicMock(stdout="uv run ci_watch.py feat")

            code = None
            with (
                patch.object(ci_watch.os, "kill", side_effect=fake_kill),
                patch.object(ci_watch.subprocess, "run", side_effect=fake_ps),
                patch.object(ci_watch.time, "sleep"),
            ):
                try:
                    ci_watch.acquire_lock("slot-1")
                except SystemExit as exc:
                    code = exc.code
            contents = lock.read_text() if lock.exists() else None
        finally:
            os.close(holder_fd)
    return {"sent": sent, "lock": contents, "code": code}


def test_acquire_lock_sigkills_a_predecessor_that_ignores_sigterm(tmp_path):
    """Two watchers on one slot both write the same state and PR-cache files.

    The predecessor's flock is what keeps the successor out, and only its death
    drops that flock — so SIGTERM must escalate to SIGKILL, or the relaunch
    never gets the slot.
    """
    out = _acquire_lock_against_predecessor(tmp_path, dies_on=signal.SIGKILL)
    assert out["sent"] == [signal.SIGTERM, signal.SIGKILL]
    assert out["lock"] == str(os.getpid())
    assert out["code"] is None


def test_acquire_lock_gives_up_on_a_predecessor_that_survives_sigkill(tmp_path, capsys):
    """A predecessor that outlives SIGKILL keeps its flock, so the slot is not
    ours to take. Exiting is the only safe answer — the old code took the lock
    anyway and put two watchers on one slot.
    """
    out = _acquire_lock_against_predecessor(tmp_path, dies_on=None)
    assert (
        out["sent"] == [signal.SIGTERM, signal.SIGKILL] * ci_watch.LOCK_ACQUIRE_ATTEMPTS
    )
    assert out["code"] == 3
    assert out["lock"] == str(os.getpid() + 12345), "the holder's pid must survive"
    captured = capsys.readouterr()
    assert "survived SIGTERM+SIGKILL" in captured.err
    assert "could not claim slot" in captured.err
    assert captured.out == "", "the warning belongs on stderr, not the event stream"


def test_acquire_lock_does_not_sigkill_a_predecessor_that_exits_on_sigterm(tmp_path):
    out = _acquire_lock_against_predecessor(tmp_path, dies_on=signal.SIGTERM)
    assert out["sent"] == [signal.SIGTERM]
    assert out["lock"] == str(os.getpid())
    assert out["code"] is None


def test_acquire_lock_does_not_sigkill_a_recycled_pid(tmp_path):
    """The predecessor may exit during the 10s SIGTERM wait and the OS may hand
    its pid to an unrelated process. SIGKILL must never hit that process, so the
    identity check runs again right before escalating."""
    out = _acquire_lock_against_predecessor(tmp_path, dies_on=None, pid_recycled=True)
    assert out["sent"] == [signal.SIGTERM]
    assert out["code"] == 3


def test_acquire_lock_claims_a_free_slot(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        lock = Path(ci_watch._lock_path("slot-1"))
        ci_watch.acquire_lock("slot-1")
        assert ci_watch._holds_lock("slot-1")
    assert lock.read_text() == str(os.getpid())


def test_acquire_lock_takes_a_slot_whose_recorded_pid_is_dead(tmp_path):
    """A watcher killed with SIGKILL leaves its lockfile behind, pid and all.

    The kernel already dropped its flock, so the slot is free: the successor
    must take it straight away, with no signals sent to whatever now owns that
    pid number.
    """
    with (
        patch.object(ci_watch, "TMP_DIR", str(tmp_path)),
        patch.object(ci_watch.os, "kill") as kill,
    ):
        lock = Path(ci_watch._lock_path("slot-1"))
        lock.write_text("999999")
        ci_watch.acquire_lock("slot-1")
    assert kill.call_count == 0, "no eviction is needed for a lock nobody holds"
    assert lock.read_text() == str(os.getpid())


def test_acquire_lock_gives_up_after_a_bounded_number_of_attempts(tmp_path, capsys):
    """A holder we cannot identify (so cannot evict) must not spin us forever."""
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        lock = Path(ci_watch._lock_path("slot-1"))
        holder_fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(holder_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.write(holder_fd, b"999999")
            with (
                patch.object(ci_watch, "_is_ci_watch_pid", return_value=False),
                pytest.raises(SystemExit) as exc,
            ):
                ci_watch.acquire_lock("slot-1")
        finally:
            os.close(holder_fd)
    assert exc.value.code == 3
    assert not ci_watch._holds_lock("slot-1")
    assert "could not claim slot" in capsys.readouterr().err


# --- Real concurrency -------------------------------------------------------
#
# The worker below is run as several real OS processes racing for one slot.
# Nothing about the lock is mocked: they call the real acquire_lock, so the
# kernel arbitrates exactly as it does in production.
#
# Its command line must not contain "ci_watch" — _is_ci_watch_pid greps `ps`
# output, and a worker that looks like a watcher would be SIGTERM'd by the next
# contender instead of being left to hold its lock. Everything therefore comes
# in through the environment, and the test asserts the command line stays clean.

_LOCK_WORKER = """
import os
import sys
import time

sys.path.insert(0, os.environ["LOCKTEST_SKILL_DIR"])
import ci_watch

ci_watch.TMP_DIR = os.environ["LOCKTEST_TMP_DIR"]
SLOT = os.environ["LOCKTEST_SLOT"]


def record(result):
    tmp = os.environ["LOCKTEST_OUT"] + ".part"
    with open(tmp, "w") as f:
        f.write(result)
    os.replace(tmp, os.environ["LOCKTEST_OUT"])


def log(line):
    with open(os.environ["LOCKTEST_LOG"], "a") as f:
        f.write(line + "\\n")


if os.environ["LOCKTEST_MODE"] == "hold":
    # One shot at the lock, then hold it until the parent has collected every
    # worker's verdict. Exactly one worker may report WON.
    try:
        ci_watch.acquire_lock(SLOT)
    except SystemExit:
        record("LOST")
        sys.exit(0)
    record("WON")
    for _ in range(600):
        if os.path.exists(os.environ["LOCKTEST_RELEASE"]):
            break
        time.sleep(0.05)
    ci_watch.release_lock(SLOT)
else:
    # Keep retrying until the slot is ours, hold it briefly, hand it on. The
    # ENTER/EXIT pairs in the log must never interleave.
    for _ in range(400):
        try:
            ci_watch.acquire_lock(SLOT)
            break
        except SystemExit:
            time.sleep(0.02)
    else:
        sys.exit(1)
    log("ENTER %d" % os.getpid())
    time.sleep(0.03)
    log("EXIT %d" % os.getpid())
    ci_watch.release_lock(SLOT)
"""

_LOCK_WORKERS = 4


def _spawn_lock_workers(tmp_path, mode: str, extra_env: dict | None = None):
    """Start ``_LOCK_WORKERS`` real processes racing for one slot."""
    worker = tmp_path / "worker.py"
    worker.write_text(_LOCK_WORKER)
    cmd = [sys.executable, str(worker)]
    assert "ci_watch" not in " ".join(cmd), (
        "a worker that looks like a watcher would be evicted by its rivals"
    )
    procs = []
    for i in range(_LOCK_WORKERS):
        env = {
            **os.environ,
            "LOCKTEST_SKILL_DIR": str(SCRIPTS_DIR),
            "LOCKTEST_TMP_DIR": str(tmp_path),
            "LOCKTEST_SLOT": "race",
            "LOCKTEST_MODE": mode,
            "LOCKTEST_OUT": str(tmp_path / f"out-{i}"),
            "LOCKTEST_LOG": str(tmp_path / "log"),
            **(extra_env or {}),
        }
        procs.append(
            subprocess.Popen(
                cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
        )
    return procs


def _finish_lock_workers(procs, timeout: float = 60.0):
    for proc in procs:
        _, err = proc.communicate(timeout=timeout)
        assert proc.returncode == 0, err.decode()


def test_acquire_lock_is_exclusive_across_real_processes(tmp_path):
    """Four processes go for the same free slot at once; one may have it.

    This is the case the previous design got wrong: every contender unlinked
    the lockfile before creating its own, so a contender could delete a rival's
    already-won claim and then "win" the empty path itself. Only a real race
    between real processes shows that — a mocked FileExistsError cannot.
    """
    procs = _spawn_lock_workers(
        tmp_path, "hold", {"LOCKTEST_RELEASE": str(tmp_path / "release")}
    )
    try:
        outs = [tmp_path / f"out-{i}" for i in range(_LOCK_WORKERS)]
        for _ in range(300):
            results = [p.read_text() for p in outs if p.exists()]
            if len(results) == _LOCK_WORKERS:
                break
            time.sleep(0.05)
        else:
            raise AssertionError(f"workers did not all report: {results}")
        assert results.count("WON") == 1, results
        assert results.count("LOST") == _LOCK_WORKERS - 1, results
        lock = Path(tmp_path / "ci_watch_lock_race")
        assert lock.read_text().isdigit(), "the winner's pid must be on disk"
    finally:
        (tmp_path / "release").write_text("go")
        _finish_lock_workers(procs)


def test_acquire_lock_hands_the_slot_over_without_overlap(tmp_path):
    """Same race, but every worker keeps retrying until it gets the slot.

    Each writes ENTER and EXIT around its turn. Two workers holding the lock at
    once would interleave those lines; perfect nesting is the proof they never
    did — and it also exercises the handover, where the holder unlinks the
    lockfile a rival already has open.
    """
    procs = _spawn_lock_workers(tmp_path, "handoff")
    _finish_lock_workers(procs)

    lines = (tmp_path / "log").read_text().split()
    events = [(lines[i], lines[i + 1]) for i in range(0, len(lines), 2)]
    assert len(events) == _LOCK_WORKERS * 2, events
    holder = None
    for kind, pid in events:
        if kind == "ENTER":
            assert holder is None, f"pid {pid} entered while {holder} held: {events}"
            holder = pid
        else:
            assert kind == "EXIT" and holder == pid, events
            holder = None
    assert holder is None
    assert len({pid for _, pid in events}) == _LOCK_WORKERS
    assert not (tmp_path / "ci_watch_lock_race").exists()


def test_release_lock_drops_our_own_lockfile(tmp_path):
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        lock = Path(ci_watch._lock_path("slot-1"))
        ci_watch.acquire_lock("slot-1")
        ci_watch.release_lock("slot-1")
        assert not ci_watch._holds_lock("slot-1")
    assert not lock.exists()


def test_release_lock_leaves_a_holders_lockfile_alone(tmp_path):
    """A watcher that never owned the slot must not unlink its lockfile.

    The /ci-watcher skill treats that file as its only liveness oracle, so a
    false DEAD makes it launch a second watcher.
    """
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        lock = Path(ci_watch._lock_path("slot-1"))
        lock.write_text(str(os.getpid() + 1))
        ci_watch.release_lock("slot-1")
    assert lock.read_text() == str(os.getpid() + 1)


@pytest.mark.parametrize("content", ["", "not-a-pid"])
def test_release_lock_ignores_the_recorded_pid(content, tmp_path):
    """Holding the flock is what makes the slot ours, not the file's contents.

    A truncated or garbled write must not strand the lockfile: the /ci-watcher
    skill would read it as a live watcher forever.
    """
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        lock = Path(ci_watch._lock_path("slot-1"))
        ci_watch.acquire_lock("slot-1")
        lock.write_text(content)
        ci_watch.release_lock("slot-1")
    assert not lock.exists()


def _captured_cleanup(tmp_path):
    """The ``cleanup`` closure that ``watch()`` registers with atexit.

    ``cleanup`` is reachable only through a real ``watch()`` run, so the loop is
    driven for one iteration and the registration is intercepted — which also
    keeps the handler from firing later, at interpreter exit.
    """
    with patch.object(ci_watch.atexit, "register") as register:
        run_watch(str(tmp_path), api_get_side_effect=make_api_get(), max_sleeps=1)
    return register.call_args.args[0]


def _lock_slot_files(tmp_path, lock_pid: int):
    """State file, PR cache and lockfile for slot ``feat``, all present."""
    state = Path(ci_watch._state_path("feat"))
    pr = Path(ci_watch._pr_path("feat"))
    lock = Path(ci_watch._lock_path("feat"))
    state.write_text("feat:running")
    pr.write_text("{}")
    lock.write_text(str(lock_pid))
    return state, pr, lock


def test_cleanup_leaves_a_holders_state_files_alone(tmp_path):
    """A watcher that lost the race (or was never the holder) must not wipe the
    live state file and PR cache the real holder is writing — the /ci-watcher
    skill reads both as the session's CI status.
    """
    cleanup = _captured_cleanup(tmp_path)
    holder_pid = os.getpid() + 1
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        state, pr, lock = _lock_slot_files(tmp_path, holder_pid)
        cleanup()
    assert state.read_text() == "feat:running"
    assert pr.read_text() == "{}"
    assert lock.read_text() == str(holder_pid)


def test_cleanup_wipes_the_slot_while_we_still_hold_the_lock(tmp_path):
    """The other half of the guard: a watcher that still owns the slot must
    clear its own files, or a stale "running" state outlives the process.
    """
    cleanup = _captured_cleanup(tmp_path)
    with patch.object(ci_watch, "TMP_DIR", str(tmp_path)):
        state, pr, lock = _lock_slot_files(tmp_path, os.getpid())
        ci_watch.acquire_lock("feat")
        cleanup()
    assert not state.exists()
    assert not pr.exists()
    assert not lock.exists()


def test_main_aborts_without_session_id(monkeypatch, capsys):
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    monkeypatch.setattr(sys, "argv", ["ci_watch.py", "br"])
    with pytest.raises(SystemExit) as exc:
        ci_watch.main()
    assert exc.value.code == 2
    assert "CLAUDE_CODE_SESSION_ID" in capsys.readouterr().err


@pytest.mark.parametrize(
    "argv",
    [
        # Legacy webhook-era invocation: branch + port + session token.
        ["ci_watch.py", "br", "1234", "tok"],
        # Branch + port, the half-migrated form.
        ["ci_watch.py", "br", "1234"],
        # No branch at all.
        ["ci_watch.py"],
    ],
)
def test_main_rejects_wrong_argument_count(argv, monkeypatch, capsys):
    """The CLI takes exactly one positional arg now. A stale launcher still
    passing port/token must fail loudly instead of watching a branch named
    after its own port.
    """
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "slot-1")
    monkeypatch.setattr(sys, "argv", argv)
    with pytest.raises(SystemExit) as exc:
        ci_watch.main()
    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "Usage: ci_watch.py <branch>" in captured.err
    # Even the usage error stays off the notification stream.
    assert captured.out == ""


@pytest.mark.parametrize("branch", ["", "   "])
def test_main_rejects_an_empty_branch(branch, monkeypatch, capsys):
    """An unsubstituted Monitor command template expands its placeholders to
    empty strings, and ``cd ''`` succeeds — so an empty branch is a real
    launch shape. Fail here, not with a confusing "branch not found" later.
    """
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "slot-1")
    monkeypatch.setattr(sys, "argv", ["ci_watch.py", branch])
    with pytest.raises(SystemExit) as exc:
        ci_watch.main()
    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "branch argument is empty" in captured.err
    assert captured.out == ""


def test_main_passes_resolved_repo_context_to_watch(monkeypatch):
    """``watch`` takes six same-typed positional strings. Nothing else pins
    their order, so a transposition of ``owner``/``repo`` (or
    ``default_branch``/``latest_sha``) would ship green.
    """
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "slot-1")
    monkeypatch.setattr(sys, "argv", ["ci_watch.py", "feat/x"])

    with (
        patch.object(ci_watch, "acquire_lock"),
        patch.object(ci_watch, "gh_token_value", return_value="tok"),
        patch.object(
            ci_watch, "repo_info", return_value=("the-owner", "the-repo", "main")
        ),
        patch.object(ci_watch, "resolve_branch_sha", return_value="sha-123"),
        patch.object(ci_watch, "watch") as watch_mock,
    ):
        ci_watch.main()

    assert watch_mock.call_args.args == (
        "feat/x",
        "slot-1",
        "the-owner",
        "the-repo",
        "main",
        "sha-123",
    )


# ---------------------------------------------------------------------------
# Repo hygiene: the webhook mechanism is gone for good
# ---------------------------------------------------------------------------

REPO_DIR = Path(__file__).parent.parent


def test_no_dangling_references_to_the_removed_webhook_mechanism():
    """Every artifact of the retired mechanism must be gone. A leftover
    reference (a launcher passing a port, a kill-flag touch, the npm channel
    dir) silently breaks the watcher instead of failing at setup time.
    """
    forbidden = [
        "ci_watch_kill_",  # kill-flag stop mechanism, replaced by TaskStop
        "ci_watch_oneshot",  # deleted script
        "dangerously-load-development-channels",  # old cc alias flag
        "mcp__webhook",  # webhook MCP tool ids
        "npx tsx",  # webhook.ts launcher
    ]
    tracked = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_DIR,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split("\0")

    hits: list[str] = []
    for rel in tracked:
        # Test files name the retired tokens on purpose, in negative assertions
        # (this scan itself, and the bats suites' assert_not_contains checks).
        # Everything else — scripts/, skills/, docs/, setup.sh, settings.json —
        # is scanned, because a stale launcher snippet in any of them breaks the
        # watcher silently.
        if not rel or rel.startswith("tests/"):
            continue
        path = REPO_DIR / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        hits += [f"{rel}: {tok}" for tok in forbidden if tok in text]
    assert hits == [], f"dangling references to the removed webhook path: {hits}"


def test_deleted_paths_are_really_gone():
    assert not (REPO_DIR / "channel").exists()
    assert not (REPO_DIR / "scripts" / "ci_watch_oneshot.sh").exists()


def test_ci_watch_module_has_no_webhook_surface():
    """``notify`` posting over HTTP and the health-check loop are gone: nothing
    in the module may reach for them again.
    """
    assert not hasattr(ci_watch, "health_check")
    assert not hasattr(ci_watch, "_kill_path")
    assert not hasattr(ci_watch, "HEALTH_RETRY_MAX")
    source = (SCRIPTS_DIR / "ci_watch.py").read_text()
    assert "requests.post" not in source
