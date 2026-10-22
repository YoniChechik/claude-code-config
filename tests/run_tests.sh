#!/usr/bin/env bash
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0

if ! command -v shfmt >/dev/null 2>&1; then
    echo "!! shfmt not found — the bashparse tests will fail (install: brew install shfmt)" >&2
    rc=1
fi

if ! command -v bats >/dev/null 2>&1; then
    echo "!! bats not found — skipping bash tests (install: brew install bats-core)" >&2
    exit 1
fi

ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
jobs="${BATS_FILE_JOBS:-$((ncpu / 2))}"
((jobs > 6)) && jobs=6
((jobs < 1)) && jobs=1

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo "== bats: shell hook/skill logic ($jobs files in parallel) =="

export OUT_DIR="$out"
ls -S "$TESTS_DIR"/*.bats |
    xargs -P "$jobs" -I{} bash -c '
        f="$1"
        name="$(basename "$f" .bats)"
        start=$SECONDS
        bats --tap "$f" >"$OUT_DIR/$name.tap" 2>&1
        echo $? >"$OUT_DIR/$name.rc"
        echo "$((SECONDS - start))" >"$OUT_DIR/$name.secs"
    ' _ {}

total=0
failed=0
for tap in "$out"/*.tap; do
    name="$(basename "$tap" .tap)"
    n="$(grep -c '^\(ok\|not ok\) ' "$tap")"
    nf="$(grep -c '^not ok ' "$tap")"
    file_rc="$(cat "$out/$name.rc")"
    total=$((total + n))
    failed=$((failed + nf))
    status=ok
    if [ "$file_rc" -ne 0 ] || [ "$nf" -gt 0 ]; then
        status=FAIL
        rc=1
    fi
    printf '%-4s %-45s %4s tests %4ss\n' "$status" "$name" "$n" "$(cat "$out/$name.secs")"
    if [ "$status" = FAIL ]; then
        grep -v '^ok ' "$tap" | sed 's/^/    /'
    fi
done

echo "== $total tests, $failed failed =="
exit "$rc"
