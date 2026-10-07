#!/usr/bin/env bash

HOOK_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && HOOK_DIR=${BASH_SOURCE[0]%/*}

source "$HOOK_DIR/_hook_log.sh" 2>/dev/null || exit 0
source "$HOOK_DIR/_bashparse.sh" 2>/dev/null || skip "bashparse library missing"

IFS= read -r -d '' input

case "$input" in
    *gh*pr*merge*) ;;
    *) skip "no candidate substring" ;;
esac

bp_parse_hook "$input" || skip "parse failed: $BP_ERR"
[ "$BP_TOOL" = "Bash" ] || skip "not a Bash tool call"
bp_find gh pr merge || skip "no gh pr merge command"

cwd=""
for i in "${BP_MATCHES[@]}"; do
    bp_seg "$i"
    for w in "${SEG_ARGV[@]}"; do
        case "$w" in -h | --help | --help=*) continue 2 ;; esac
    done
    [ "$SEG_CWD_KNOWN" = "1" ] || continue
    cwd="$SEG_CWD"
    break
done
[ -n "$cwd" ] || skip "no gh pr merge with a known directory and no help flag"

common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
[ -n "$common_dir" ] || skip "not a git repo: $cwd"
case "$common_dir" in
    /*) ;;
    *) common_dir="$cwd/$common_dir" ;;
esac
primary_root=$(cd "${common_dir%/*}" 2>/dev/null && pwd) || skip "primary checkout not found for $common_dir"

source "$HOOK_DIR/_git_sync.sh" 2>/dev/null || skip "_git_sync.sh missing"
hook_log "sync: $primary_root"
_sync_primary_checkout_to_origin_main "$primary_root"

exit 0
