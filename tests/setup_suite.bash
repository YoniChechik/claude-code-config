setup_suite() {
    export BATS_REAL_HOME="$HOME"
    export BATS_REAL_HOOK_LOGS="$HOME/.claude/logs"
    export HOME="$BATS_SUITE_TMPDIR/home"
    mkdir -p "$HOME"
    unset CLAUDE_HOOK_LOG_DIR
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    git config --global user.email "t@example.com"
    git config --global user.name "t"
    git config --global init.defaultBranch main
    export UV_CACHE_DIR="${UV_CACHE_DIR:-$BATS_REAL_HOME/.cache/uv}"
    export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$BATS_REAL_HOME/.local/share/uv/python}"
}

teardown_suite() {
    local f
    for f in "$BATS_REAL_HOOK_LOGS/hooks.log" "$BATS_REAL_HOOK_LOGS/hooks.log.1"; do
        [ -f "$f" ] || continue
        if grep -qF -- "${BATS_RUN_TMPDIR##*/}" "$f"; then
            echo "a test wrote to the real hook log $f" >&2
            return 1
        fi
    done
}
