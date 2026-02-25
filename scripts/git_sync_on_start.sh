#!/usr/bin/env bash

git fetch origin --quiet

state=$(bash "$HOME/.claude/scripts/git_branch_state.sh")
[ -z "$state" ] && exit 0

branch=$(echo "$state" | jq -r '.branch')
diverged=$(echo "$state" | jq -r '.diverged')
behind_main=$(echo "$state" | jq -r '.behind_main')

[ "$diverged" = "false" ] && [ "$behind_main" = "0" ] && exit 0

GREEN='\033[32m'
BOLD_GREEN='\033[1;32m'
YELLOW='\033[33m'
RESET='\033[0m'
SEP="════════════════════════════════════════"

_print_output() {
    printf "${GREEN}${SEP}${RESET}\n"
    printf "${BOLD_GREEN}  Git Branch State${RESET}\n"
    printf "  Branch: %s\n" "$branch"
    if [ "$diverged" = "true" ]; then
        printf "${YELLOW}  ⚠ Diverged from origin. Run: git pull${RESET}\n"
    fi
    if [ "$behind_main" != "0" ]; then
        printf "${YELLOW}  ⚠ %s commit(s) behind main. Run: /sync${RESET}\n" "$behind_main"
    fi
    printf "${GREEN}${SEP}${RESET}\n"
}

_print_output
_print_output >&2
