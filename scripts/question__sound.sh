#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# PreToolUse hook for AskUserQuestion: green tab + chime + "waiting" title.
#
# A raised question BLOCKS — the turn does not continue until the user picks an
# answer (settings.json even gives it a 10m timeout) — so this takes the
# blocking entry point, which never checks for background work. The rule and its
# reasoning live at notify_user_attention_blocking in _notify.sh.
notify_user_attention_blocking
