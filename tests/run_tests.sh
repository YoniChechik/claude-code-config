#!/usr/bin/env bash
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0

if ! command -v shfmt >/dev/null 2>&1; then
    echo "!! shfmt not found — the bashparse tests will fail (install: brew install shfmt)" >&2
    rc=1
fi

if command -v bats >/dev/null 2>&1; then
    echo "== bats: shell hook/skill logic =="
    bats "$TESTS_DIR"/*.bats || rc=1
else
    echo "!! bats not found — skipping bash tests (install: brew install bats-core)" >&2
    rc=1
fi

exit "$rc"
