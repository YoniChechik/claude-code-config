#!/usr/bin/env bats

SETUP_SH="${BATS_TEST_DIRNAME}/../setup.sh"

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/.git"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    BREW_LOG="$BATS_TEST_TMPDIR/brew.log"
    export BREW_LOG
}

assert_contains() {
    case "$2" in (*"$1"*) return 0 ;; esac
    printf 'expected to CONTAIN: %s\nactual: %s\n' "$1" "$2" >&2
    return 1
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2
    return 1
}

stub() {
    printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

run_setup() {
    run env PATH="$STUBS:/usr/bin:/bin" "$BASH" "$SETUP_SH"
}

@test "shfmt already installed: reports the version and never calls brew" {
    stub shfmt 'echo v3.14.1'
    stub brew 'echo "$*" >>"$BREW_LOG"'
    run_setup
    assert_eq 0 "$status"
    assert_contains "shfmt already installed (v3.14.1)" "$output"
    assert_contains "Done!" "$output"
    [ ! -e "$BREW_LOG" ]
}

@test "Homebrew present: installs shfmt with brew" {
    stub brew 'echo "$*" >>"$BREW_LOG"'
    run_setup
    assert_eq 0 "$status"
    assert_contains "Installing shfmt" "$output"
    assert_eq "install shfmt" "$(cat "$BREW_LOG")"
    assert_contains "Done!" "$output"
}

@test "failed brew install warns and still finishes setup" {
    stub brew 'echo "$*" >>"$BREW_LOG"; exit 1'
    run_setup
    assert_eq 0 "$status"
    assert_contains "WARNING: brew install shfmt failed." "$output"
    assert_contains "Done!" "$output"
}

@test "no Homebrew: explains the manual install and still finishes setup" {
    run_setup
    assert_eq 0 "$status"
    assert_contains "Skipping shfmt install: Homebrew not found." "$output"
    assert_contains "https://github.com/mvdan/sh/releases" "$output"
    assert_contains "Done!" "$output"
}
