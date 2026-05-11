#!/usr/bin/env bash

notify_user_attention() {
    printf '\033]6;1;bg;red;brightness;0\a\033]6;1;bg;green;brightness;180\a\033]6;1;bg;blue;brightness;0\a' > /dev/tty 2>/dev/null || true

    if command -v afplay >/dev/null 2>&1; then
        afplay /System/Library/Sounds/Glass.aiff </dev/null >/dev/null 2>&1 &
        disown
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-repo")
    printf '\033]0;🔴 %s waiting... 🔔\007' "$branch"
}
