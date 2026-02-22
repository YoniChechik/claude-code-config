#!/usr/bin/env bash

notify_waiting() {
    afplay /System/Library/Sounds/Glass.aiff
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-repo")
    printf '\033]0;🔴 %s waiting... 🔔\007' "$branch"
}
