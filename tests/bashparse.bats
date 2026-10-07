#!/usr/bin/env bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
BASHPARSE="$SCRIPTS/bashparse"
LIB="$SCRIPTS/_bashparse.sh"
CORPUS="${BATS_TEST_DIRNAME}/fixtures/bashparse_corpus.jsonl"

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

stub_bin() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

link_bin() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    ln -sf "$(command -v "$1")" "$BATS_TEST_TMPDIR/stubs/$1"
}

CHECK='
def kp: [scan("[^.\\[\\]]+") | if test("^[0-9]+$") then tonumber else . end];
def m($e): . as $s | all($e | to_entries[]; (.key | kp) as $k | .value as $v | ($s | getpath($k)) == $v);
. as $segs
| ([($row.has // [])[] as $e | select(([$segs[] | m($e)] | any) | not) | "missing: \($e | tojson)"]
  + [($row.none // [])[] as $e | select([$segs[] | m($e)] | any) | "unexpected: \($e | tojson)"]
  + [($row.count // [])[] as $c | ([$segs[] | select(m($c.match))] | length) as $n
      | select($n != $c.n) | "count \($c.match | tojson) = \($n), want \($c.n)"])
| .[]'

check_row() {
    local row=${CORPUS_ROWS[$1]} cmd cwd depth cdpath rc out problems
    cmd=$(jq -r .cmd <<<"$row")
    cwd=$(jq -r '.cwd // "/start"' <<<"$row")
    depth=$(jq -r '.depth // 4' <<<"$row")
    cdpath=$(jq -r '.env.CDPATH // ""' <<<"$row")
    rc=0
    out=$(printf '%s' "$cmd" | HOME=/home/u CDPATH="$cdpath" "$BASHPARSE" --cwd "$cwd" --depth "$depth" 2>&1) || rc=$?
    want=$(jq -r '.error // 0' <<<"$row")
    if [ "$rc" != "$want" ]; then
        printf 'exit %s, want %s\n%s\n' "$rc" "$want" "$out" >&2
        return 1
    fi
    [ "$want" != 0 ] && return 0
    problems=$(jq -r --argjson row "$row" "$CHECK" <<<"$out")
    if [ -n "$problems" ]; then
        printf '%s\n--- segments ---\n%s\n' "$problems" "$(jq -c '.[]' <<<"$out")" >&2
        return 1
    fi
}

mapfile -t CORPUS_ROWS <"$CORPUS"
mapfile -t CORPUS_NAMES < <(jq -r .name "$CORPUS")
for i in "${!CORPUS_ROWS[@]}"; do
    bats_test_function --description "corpus: ${CORPUS_NAMES[i]}" -- check_row "$i"
done

@test "every corpus row states at least one explicit expectation" {
    run jq -r 'select((.has // []) + (.none // []) + (.count // []) | length == 0) | select(.error == null) | .name' "$CORPUS"
    assert_eq "" "$output"
}

@test "segments carry the full documented field set" {
    run bash -c 'printf "git push" | "$1" --cwd /s' _ "$BASHPARSE"
    assert_eq 0 "$status"
    run jq -r '.[0] | keys_unsorted | join(" ")' <<<"$output"
    for k in id parent depth via argv dynamic cmd raw_argv wrappers env op_before pipeline_index pipeline_len \
        negated background in_subshell in_group in_substitution in_compound in_function redirects outer_redirects \
        cwd cwd_known git code unknown unknown_reasons exit_code_belongs_to_command; do
        assert_contains "$k" "$output"
    done
}

@test "failure: shfmt missing returns 3 with a reason" {
    link_bin jq
    run env PATH="$BATS_TEST_TMPDIR/stubs" "$BASH" -c 'source "$1"; bp_parse "git push" /s; echo "rc=$? err=$BP_ERR json=[$BP_JSON]"' _ "$LIB"
    assert_eq "rc=3 err=shfmt not installed json=[]" "$output"
}

@test "failure: CLI exits 3 and explains when shfmt is missing" {
    link_bin jq
    run env PATH="$BATS_TEST_TMPDIR/stubs" "$BASH" "$BASHPARSE" <<<"git push"
    assert_eq 3 "$status"
    assert_eq "bashparse: shfmt not installed" "$output"
}

@test "failure: parse error returns 2 with shfmt's message" {
    run bash -c 'source "$1"; bp_parse "echo \"open" /s; echo "rc=$? err=$BP_ERR json=[$BP_JSON]"' _ "$LIB"
    assert_eq 'rc=2 err=parse error: 1:6: reached EOF without closing quote `"` json=[]' "$output"
}

@test "failure: shfmt emitting bad JSON returns 5" {
    stub_bin shfmt 'echo "this is not json"'
    link_bin jq
    link_bin sleep
    run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" "$BASH" -c 'source "$1"; bp_parse "git push" /s; echo "rc=$? json=[$BP_JSON]"; echo "$BP_ERR"' _ "$LIB"
    assert_eq "rc=5 json=[]" "${lines[0]}"
    assert_contains "jq failed:" "${lines[1]}"
}

@test "failure: jq failing returns 5" {
    link_bin shfmt
    link_bin sleep
    stub_bin jq 'echo "jq: error: boom" >&2; exit 3'
    run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" "$BASH" -c 'source "$1"; bp_parse "git push" /s; echo "rc=$? err=$BP_ERR json=[$BP_JSON]"' _ "$LIB"
    assert_eq "rc=5 err=jq failed: jq: error: boom json=[]" "$output"
}

@test "failure: jq missing returns 5" {
    link_bin shfmt
    run env PATH="$BATS_TEST_TMPDIR/stubs" "$BASH" -c 'source "$1"; bp_parse "git push" /s; echo "rc=$? err=$BP_ERR"' _ "$LIB"
    assert_eq "rc=5 err=jq not installed" "$output"
}

@test "failure: a hung shfmt times out with 4 and is killed" {
    stub_bin shfmt 'exec sleep 30'
    link_bin jq
    link_bin sleep
    start=$SECONDS
    run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" BASHPARSE_TIMEOUT=1 "$BASH" -c 'source "$1"; bp_parse "git push" /s; echo "rc=$? err=$BP_ERR json=[$BP_JSON]"' _ "$LIB"
    assert_eq "rc=4 err=timeout: parse exceeded 1s json=[]" "$output"
    [ $((SECONDS - start)) -lt 10 ]
}

@test "failure: bad hook input JSON returns 6" {
    run bash -c 'source "$1"; bp_parse_hook "{not json"; echo "rc=$? err=$BP_ERR"' _ "$LIB"
    assert_eq "rc=6 err=bad hook input JSON" "$output"
}

@test "failure: hook input without a string command returns 6" {
    run bash -c 'source "$1"; bp_parse_hook "{\"tool_input\":{\"command\":7}}"; echo "rc=$? err=$BP_ERR"' _ "$LIB"
    assert_eq "rc=6 err=bad hook input JSON" "$output"
}

@test "bp_parse_hook reads the command and cwd and sets HOOK_LOG_CMD" {
    run bash -c 'source "$1"; bp_parse_hook "$(jq -cn "{tool_input: {command: \"cd w && git push\"}, cwd: \"/repo\"}")" || exit 9
        bp_find git push; bp_seg "${BP_MATCHES[0]}"; echo "$BP_CMD|$HOOK_LOG_CMD|$SEG_CWD"' _ "$LIB"
    assert_eq "cd w && git push|cd w && git push|/repo/w" "$output"
}

@test "bp_find matches argv prefixes, normalizes git options and skips substitutions" {
    run bash -c 'source "$1"; bp_parse "git -C /x push; echo \$(gh pr merge 1); gh pr merge 2 && echo \"gh pr merge 3\"" /s
        bp_find git push && echo "push=${BP_MATCHES[*]}"
        bp_find gh pr merge && echo "merge=${BP_MATCHES[*]}"
        bp_find --all gh pr merge && echo "all=${BP_MATCHES[*]}"
        bp_find gh pr create || echo "create=none"' _ "$LIB"
    assert_eq $'push=0\nmerge=3\nall=2 3\ncreate=none' "$output"
}

@test "bp_seg returns real array elements, including spaces and newlines" {
    run bash -c 'source "$1"; bp_parse "gh pr create --title \"a b\" --body \"l1
l2\"" /s; bp_seg 0; printf "<%s>" "${SEG_ARGV[@]}"' _ "$LIB"
    assert_eq $'<gh><pr><create><--title><a b><--body><l1\nl2>' "$output"
}

@test "bp_seg exposes git subcommand, args, config and effective repo directory" {
    run bash -c 'source "$1"; bp_parse "cd /r && git -c a=b -C sub commit -m \"x y\"" /s; bp_seg 1
        printf "%s|%s|%s|%s|" "$SEG_GIT_SUB" "$SEG_GIT_CWD" "$SEG_GIT_CWD_KNOWN" "${SEG_GIT_CONFIG[*]}"; printf "<%s>" "${SEG_GIT_ARGS[@]}"
        bp_seg 0; echo " git=$SEG_GIT"' _ "$LIB"
    assert_eq "commit|/r/sub|1|a=b|<-m><x y> git=0" "$output"
}

@test "bp_unknown reports every reason once" {
    run bash -c 'source "$1"; bp_parse "eval \"\$X\"; \$Y; \$Z" /s; bp_unknown && printf "%s," "${BP_UNKNOWN_REASONS[@]}"
        bp_parse "git push" /s; bp_unknown || echo none' _ "$LIB"
    assert_eq $'dynamic eval,dynamic command name,none' "$output"
}

@test "bp_segments_text is one display line per segment" {
    run bash -c 'source "$1"; bp_parse "/usr/bin/git push && rtk gh pr create --body \"a
b\"" /s; bp_segments_text' _ "$LIB"
    assert_eq $'git push\ngh pr create --body a\\nb' "$output"
}

@test "bp_parse without a cwd uses PWD and an unknown relative cwd stays unknown" {
    run bash -c 'cd /tmp && source "$1" && bp_parse "git push" && bp_seg 0 && printf "%s|%s" "$SEG_CWD" "$SEG_CWD_KNOWN"' _ "$LIB"
    assert_eq '/tmp|1' "$output"
}
