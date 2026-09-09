#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# PreToolUse hook for AskUserQuestion: green tab + chime + "waiting" title.
#
# notify_user_attention is called with NO transcript ON PURPOSE. The argument is
# what enables the background-work gate that paints BLUE and swallows the chime,
# and a raised question BLOCKS: the turn does not continue until the user picks
# an answer (settings.json even gives it a 10m timeout). A live Monitor,
# backgrounded Bash or CI watcher does not make the session less stuck, so
# "needs attention" always wins here — exactly as on the permission-guard's
# `ask` path.
notify_user_attention
