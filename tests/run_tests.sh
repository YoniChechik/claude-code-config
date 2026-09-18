#!/usr/bin/env bash
#
# Run the full test suite for this repo:
#   - bash hook/notify logic via bats (tests/*.bats)
#
# Usage: tests/run_tests.sh
set -u

# Resolve the tests dir regardless of where this is invoked from.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0

# --- bats (bash) -----------------------------------------------------------
if command -v bats >/dev/null 2>&1; then
    echo "== bats: shell hook/skill logic =="
    bats "$TESTS_DIR"/*.bats || rc=1
else
    echo "!! bats not found — skipping bash tests (install: brew install bats-core)" >&2
    rc=1
fi

exit "$rc"
