#!/usr/bin/env bash
#
# Run the full test suite for this repo:
#   - bash hook/notify logic via bats (tests/*.bats)
#   - the ci_watch python integration tests via uv + pytest
#
# Usage: tests/run_tests.sh
set -u

# Resolve the tests dir regardless of where this is invoked from.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

rc=0

# --- bats (bash) -----------------------------------------------------------
if command -v bats >/dev/null 2>&1; then
    echo "== bats: notify / stop-decision logic =="
    bats "$TESTS_DIR"/*.bats || rc=1
else
    echo "!! bats not found — skipping bash tests (install: brew install bats-core)" >&2
    rc=1
fi

# --- pytest (python ci_watch) ---------------------------------------------
# The python test file declares its deps via PEP 723 inline metadata, but we
# run it through pytest so test discovery/reporting works; pass the deps to uv.
if command -v uv >/dev/null 2>&1; then
    echo "== pytest: ci_watch integration =="
    uv run --quiet --with pytest --with requests \
        -m pytest "$TESTS_DIR/test_ci_watch_integration.py" -q || rc=1
else
    echo "!! uv not found — skipping python tests" >&2
    rc=1
fi

exit "$rc"
