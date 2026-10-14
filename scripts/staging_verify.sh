#!/usr/bin/env bash

set -uo pipefail

: "${STAGING_VERIFY_POLL:=20}"
: "${STAGING_VERIFY_PROBE_TIMEOUT:=60}"
: "${STAGING_VERIFY_DEFAULT_TIMEOUT:=1800}"
: "${CLAUDE_VERIFY_DIR:=$HOME/.claude/verify}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_state.sh"

(($# == 5)) || { echo "Usage: staging_verify.sh <owner/repo> <target> <pr-number> <merge-sha> <ci: pass|fail|timeout|none>" >&2; exit 2; }
REPO=$1
TARGET=$2
PR=$3
SHA=$4
CI=$5
CURL_HTTPS=(--proto "=https" --proto-redir "=https" -sS)

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

[[ $REPO =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] || record error "invalid repository name '${REPO}'"
[[ $SHA =~ ^[0-9a-f]{7,40}$ ]] || record error "invalid merge commit '${SHA}'"

case "$CI" in
    pass | none) ;;
    *) record fail "post-merge CI ${CI}" ;;
esac

CONFIG_FILE="$CLAUDE_VERIFY_DIR/${REPO%%/*}__${REPO#*/}.json"
[[ -e $CONFIG_FILE || -L $CONFIG_FILE ]] || record no-config "no verify config at ${CONFIG_FILE}. Create it with /create-verification-skill."
state_safe_file "$CONFIG_FILE" || record error "untrusted verify config: ${STATE_ERR}"
config=$(<"$CONFIG_FILE") || record error "cannot read ${CONFIG_FILE}"
config_sha=$(printf '%s' "$config" | shasum -a 256 | cut -d' ' -f1)

problems=$(jq -r '
    def https: type == "string" and test("^https://[^\\s]+$");
    if type != "object" or (.targets | type) != "array" then "no targets array"
    else
        [.targets | to_entries[] | .key as $i | .value as $t
            | if ($t | type) != "object" then "target \($i) is not an object"
              elif ($t.sha_url | https | not) then "target \($i): sha_url must be an https:// URL"
              elif (($t.probes // []) | type) != "array" then "target \($i): probes is not an array"
              else (($t.probes // []) | to_entries[] | .key as $j | .value as $p
                  | if ($p | type) != "object" then "target \($i) probe \($j) is not an object"
                    elif $p.cmd != null then "target \($i) probe \($j): shell probes are not supported, use url"
                    elif ($p.url | https | not) then "target \($i) probe \($j): url must be an https:// URL"
                    elif ($p.expect_status // 200 | type) != "number" then "target \($i) probe \($j): expect_status is not a number"
                    else empty end)
              end] | join("; ")
    end' <<<"$config" 2>/dev/null) || record error "${CONFIG_FILE} is not valid JSON"
[[ -z $problems ]] || record error "invalid ${CONFIG_FILE}: ${problems}" "[]" "$config_sha"

if [[ $(jq '.targets | length' <<<"$config") -eq 0 ]]; then
    record n/a "$(jq -r '.reason // "targets: [] in the verify config"' <<<"$config")" "[]" "$config_sha"
fi

WORK=$(mktemp -d) || record error "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT

contains_merge() {
    [[ $1 =~ ^[0-9a-f]{7,40}$ ]] || return 1
    local status
    status=$(gh api "repos/${REPO}/compare/${SHA}...${1}" --jq .status 2>/dev/null) || return 1
    [[ $status == ahead || $status == identical ]]
}

wait_for_sha() {
    local name=$1 url=$2 filter=$3 timeout_s=$4 start checked=""
    OBSERVED=""
    CONTAINS=false
    start=$EPOCHSECONDS
    while :; do
        OBSERVED=$(curl "${CURL_HTTPS[@]}" -f --max-time 20 -- "$url" 2>/dev/null | jq -r "($filter) | strings" 2>/dev/null)
        OBSERVED=${OBSERVED//[[:space:]]/}
        if [[ ${#OBSERVED} -ge 7 && $SHA == "$OBSERVED"* ]]; then
            CONTAINS=true
            return 0
        fi
        if [[ -n $OBSERVED && $OBSERVED != "$checked" ]]; then
            checked=$OBSERVED
            if contains_merge "$OBSERVED"; then
                CONTAINS=true
                return 0
            fi
        fi
        if ((EPOCHSECONDS - start >= timeout_s)); then
            failures+=("${name}: ${url} serves '${OBSERVED:-nothing}', which does not contain ${SHA:0:12}, after ${timeout_s}s")
            return 1
        fi
        sleep "$STAGING_VERIFY_POLL"
    done
}

run_probe() {
    local name=$1 url=$2 want=$3 expect=$4 body="$WORK/body" code prc matched=true found=true out out_sha detail
    code=$(curl "${CURL_HTTPS[@]}" --max-time "$STAGING_VERIFY_PROBE_TIMEOUT" -o "$body" -w '%{http_code}' -- "$url" 2>"$WORK/err")
    prc=$?
    [[ -f $body ]] || : >"$body"
    out=$(head -c 2048 "$body")
    ((prc == 0)) || out=$(head -c 2048 "$WORK/err")
    out_sha=$(shasum -a 256 <"$body" | cut -d' ' -f1)
    [[ -z $expect ]] || grep -qF -- "$expect" "$body" || found=false
    [[ $code == "$want" && $found == true ]] || matched=false
    total=$((total + 1))
    if ((prc == 0)) && [[ $matched == true ]]; then
        ok=$((ok + 1))
    else
        detail="curl exit ${prc}, HTTP ${code:-none}"
        [[ $code == "$want" ]] || detail+=", expected HTTP ${want}"
        [[ $found == true ]] || detail+=", expected \"${expect}\""
        failures+=("${name}: probe ${url} ${detail}: ${out:0:200}")
    fi
    probe_lines+=("$(jq -nc --arg u "$url" --arg c "$code" --argjson e "$prc" --argjson m "$matched" --arg o "$out" --arg s "$out_sha" \
        '{url: $u, status: $c, exit: $e, matched: $m, out_head: $o, out_sha256: $s}')")
    rm -f "$body"
}

target_lines=()
failures=()
summary=()
while IFS= read -r -d '' name && IFS= read -r -d '' sha_url && IFS= read -r -d '' sha_jq &&
    IFS= read -r -d '' timeout_s && IFS= read -r -d '' probes; do
    [[ $timeout_s =~ ^[0-9]+$ ]] || timeout_s=$STAGING_VERIFY_DEFAULT_TIMEOUT
    wait_for_sha "$name" "$sha_url" "$sha_jq" "$timeout_s"
    probe_lines=()
    ok=0
    total=0
    while IFS= read -r -d '' url && IFS= read -r -d '' want && IFS= read -r -d '' expect; do
        run_probe "$name" "$url" "$want" "$expect"
    done < <(jq -j '.[] | .url, "\u0000", (.expect_status // 200 | tostring), "\u0000", (.expect // "" | tostring), "\u0000"' <<<"$probes")
    target_lines+=("$(printf '%s\n' "${probe_lines[@]}" | jq -sc --arg n "$name" --arg o "$OBSERVED" --argjson c "$CONTAINS" \
        '{name: $n, observed_sha: $o, contains_merge: $c, probes: .}')")
    summary+=("${name} serves ${OBSERVED:0:12}, ${ok}/${total} probes ok")
done < <(jq -j '.targets[] | (.name // "target" | tostring), "\u0000", .sha_url, "\u0000", (.sha_jq // ".sha"), "\u0000",
    (.timeout_s // "" | tostring), "\u0000", ((.probes // []) | tojson), "\u0000"' <<<"$config")

all_targets=$(printf '%s\n' "${target_lines[@]}" | jq -sc .)

if ((${#failures[@]} > 0)); then
    record fail "$(IFS='; '; printf '%s' "${failures[*]}")" "$all_targets" "$config_sha"
fi
record pass "$(IFS='; '; printf '%s' "${summary[*]}")" "$all_targets" "$config_sha"
