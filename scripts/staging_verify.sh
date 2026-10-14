#!/usr/bin/env bash

set -uo pipefail

: "${STAGING_VERIFY_POLL:=20}"
: "${STAGING_VERIFY_PROBE_TIMEOUT:=120}"
: "${STAGING_VERIFY_DEFAULT_TIMEOUT:=1800}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_state.sh"

(($# == 5)) || { echo "Usage: staging_verify.sh <owner/repo> <target> <pr-number> <merge-sha> <ci: pass|fail|timeout|none>" >&2; exit 2; }
REPO=$1
TARGET=$2
PR=$3
SHA=$4
CI=$5

record() {
    local result=$1 reason=$2 targets=${3:-[]} config_sha=${4:-}
    local session=${CLAUDE_CODE_SESSION_ID:-}
    if [[ -n $session ]] && state_init "$session"; then
        ledger_append "$(jq -nc --arg repo "$REPO" --arg target "$TARGET" --arg pr "$PR" --arg sha "$SHA" \
            --arg result "$result" --arg reason "$reason" --arg cfg "$config_sha" --argjson targets "$targets" \
            '{kind: "verify", repo: $repo, target: $target, pr: $pr, merge_sha: $sha, result: $result, reason: $reason, config_sha: $cfg, targets: $targets}')" ||
            echo "Staging verify: could not write the session ledger" >&2
    fi
    case "$result" in
        pass) echo "Staging verify PASSED for ${REPO} (merge commit ${SHA}): ${reason}" ;;
        n/a) echo "Staging verify N/A for ${REPO}: ${reason}" ;;
        no-config) echo "Staging verify NOT CONFIGURED for ${REPO}: ${reason}" ;;
        *) echo "Staging verify FAILED for ${REPO} (merge commit ${SHA}): ${reason}" ;;
    esac
    exit 0
}

case "$CI" in
    pass | none) ;;
    *) record fail "post-merge CI ${CI}" ;;
esac

parent=$(gh api "repos/${REPO}/commits/${SHA}" --jq '.parents[0].sha' 2>/dev/null) || record error "could not read the parent of merge commit ${SHA}"
parent=${parent//[[:space:]]/}
[[ $parent =~ ^[0-9a-f]{7,40}$ ]] || record error "merge commit ${SHA} has no readable parent"

content=$(gh api "repos/${REPO}/contents/.claude/verify.json?ref=${parent}" --jq '.content' 2>&1)
rc=$?
if ((rc != 0)); then
    case "$content" in
        *"Not Found"* | *404*) record no-config "no .claude/verify.json on the base branch (${parent:0:12}). Create it with /create-verification-skill." ;;
        *) record error "could not read .claude/verify.json at ${parent:0:12}: ${content:0:200}" ;;
    esac
fi
config=$(printf '%s' "$content" | tr -d '\n' | base64 -d 2>/dev/null) || record error "verify.json content is not base64"
jq -e '(.targets | type) == "array"' <<<"$config" >/dev/null 2>&1 || record error "verify.json has no targets array"
config_sha=$(printf '%s' "$config" | shasum -a 256 | cut -d' ' -f1)

if [[ $(jq '.targets | length' <<<"$config") -eq 0 ]]; then
    record n/a "$(jq -r '.reason // "targets: [] on the base branch"' <<<"$config")" "[]" "$config_sha"
fi

run_probe() {
    perl -e 'alarm shift; exec @ARGV' "$STAGING_VERIFY_PROBE_TIMEOUT" bash -c "$1" 2>&1 </dev/null
}

all_targets="[]"
failures=()
summary=()
while IFS= read -r target; do
    name=$(jq -r '.name // "target"' <<<"$target")
    sha_url=$(jq -r '.sha_url // empty' <<<"$target")
    sha_jq=$(jq -r '.sha_jq // ".sha"' <<<"$target")
    timeout_s=$(jq -r '.timeout_s // empty' <<<"$target")
    [[ $timeout_s =~ ^[0-9]+$ ]] || timeout_s=$STAGING_VERIFY_DEFAULT_TIMEOUT
    observed=""
    if [[ -z $sha_url ]]; then
        failures+=("${name}: no sha_url, so the deployed commit cannot be checked")
    else
        start=$(date +%s)
        while :; do
            observed=$(curl -fsS --max-time 20 "$sha_url" 2>/dev/null | jq -r "$sha_jq" 2>/dev/null)
            observed=${observed//[[:space:]]/}
            [[ ${#observed} -ge 7 && $SHA == "$observed"* ]] && break
            if (($(date +%s) - start >= timeout_s)); then
                failures+=("${name}: ${sha_url} serves '${observed:-nothing}', not ${SHA:0:12}, after ${timeout_s}s")
                break
            fi
            sleep "$STAGING_VERIFY_POLL"
        done
    fi
    probes="[]"
    ok=0
    total=0
    while IFS= read -r probe; do
        [[ -n $probe ]] || continue
        cmd=$(jq -r '.cmd // empty' <<<"$probe")
        expect=$(jq -r '.expect // empty' <<<"$probe")
        out=$(run_probe "$cmd")
        prc=$?
        matched=true
        [[ -z $expect || $out == *"$expect"* ]] || matched=false
        total=$((total + 1))
        if ((prc == 0)) && [[ $matched == true ]]; then
            ok=$((ok + 1))
        else
            detail="exit ${prc}"
            [[ $matched == true ]] || detail+=", expected \"${expect}\""
            failures+=("${name}: probe \`${cmd}\` ${detail}: ${out:0:200}")
        fi
        probes=$(jq -c --arg c "$cmd" --argjson e "$prc" --argjson m "$matched" --arg o "${out:0:2048}" \
            --arg s "$(printf '%s' "$out" | shasum -a 256 | cut -d' ' -f1)" \
            '. + [{cmd: $c, exit: $e, matched: $m, out_head: $o, out_sha256: $s}]' <<<"$probes")
    done < <(jq -c '.probes // [] | .[]' <<<"$target")
    all_targets=$(jq -c --arg n "$name" --arg o "$observed" --argjson p "$probes" '. + [{name: $n, observed_sha: $o, probes: $p}]' <<<"$all_targets")
    summary+=("${name} serves ${observed:0:12}, ${ok}/${total} probes ok")
done < <(jq -c '.targets[]' <<<"$config")

if ((${#failures[@]} > 0)); then
    record fail "$(IFS='; '; printf '%s' "${failures[*]}")" "$all_targets" "$config_sha"
fi
record pass "$(IFS='; '; printf '%s' "${summary[*]}")" "$all_targets" "$config_sha"
