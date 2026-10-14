#!/usr/bin/env bash

set -uo pipefail

input=$(cat)

session_id=$(jq -r '.session_id // empty' <<< "$input" 2>/dev/null)
if [ -z "$session_id" ]; then
    exit 0
fi

if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_state.sh"

sidecar=$(_wakeup_next_path "$session_id" 2>/dev/null) || exit 0
if [ -z "$sidecar" ]; then
    exit 0
fi

if [ -e "$sidecar" ] && [ ! -f "$sidecar" ]; then
    exit 0
fi

entries=$(jq -c '(.session_crons // []) | select(length>0)' <<< "$input" 2>/dev/null)

_write_sidecar() {
    atomic_write "$sidecar" "$1"$'\n'"$2" 2>/dev/null
}

if [ -z "$entries" ]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

result=$(printf '%s' "$entries" | python3 -c '
import datetime
import json
import os
import sys

def parse_field(spec, lo, hi):
    if spec == "*":
        return set(range(lo, hi + 1))
    vals = set()
    for token in spec.split(","):
        base, step = token, 1
        if "/" in token:
            base, step_s = token.split("/", 1)
            step = int(step_s)
            if step <= 0:
                raise ValueError("non-positive step")
        if base == "*":
            start, end = lo, hi
        elif "-" in base:
            a, b = base.split("-", 1)
            start, end = int(a), int(b)
        else:
            start = end = int(base)
        if start < lo or end > hi or start > end:
            raise ValueError("field value out of range")
        vals.update(range(start, end + 1, step))
    return vals

def next_fire(schedule, recurring, now):
    parts = schedule.split()
    if len(parts) != 5:
        return None
    minutes = parse_field(parts[0], 0, 59)
    hours = parse_field(parts[1], 0, 23)
    doms = parse_field(parts[2], 1, 31)
    months = parse_field(parts[3], 1, 12)
    dows_raw = parse_field(parts[4], 0, 7)
    if not (minutes and hours and doms and months and dows_raw):
        return None
    dows = {d % 7 for d in dows_raw}
    dom_wild = parts[2] == "*"
    dow_wild = parts[4] == "*"

    if not recurring:
        minute, hour, day, month = min(minutes), min(hours), min(doms), min(months)
        for year in (now.year, now.year + 1):
            try:
                candidate = datetime.datetime(year, month, day, hour, minute)
            except ValueError:
                continue
            if candidate > now:
                return candidate
        return None

    t = now.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
    for _ in range(8 * 24 * 60):
        if t.month in months and t.minute in minutes and t.hour in hours:
            dom_ok = t.day in doms
            dow_ok = (t.weekday() + 1) % 7 in dows
            if dom_wild and dow_wild:
                day_ok = True
            elif dom_wild:
                day_ok = dow_ok
            elif dow_wild:
                day_ok = dom_ok
            else:
                day_ok = dom_ok or dow_ok
            if day_ok:
                return t
        t += datetime.timedelta(minutes=1)
    return None

now_override = os.environ.get("WAKEUP_STATUS_NOW_EPOCH")
if now_override:
    try:
        now = datetime.datetime.fromtimestamp(int(now_override))
    except (ValueError, OSError, OverflowError):
        now = datetime.datetime.now()
else:
    now = datetime.datetime.now()

try:
    entries = json.load(sys.stdin)
except Exception:
    entries = []
if not isinstance(entries, list):
    entries = []

best_fire = None
best_prompt = ""
for entry in entries:
    if not isinstance(entry, dict):
        continue
    schedule = entry.get("schedule")
    if not isinstance(schedule, str):
        continue
    try:
        fire = next_fire(schedule, bool(entry.get("recurring")), now)
    except Exception:
        continue
    if fire is None:
        continue
    if best_fire is None or fire < best_fire:
        best_fire = fire
        prompt = entry.get("prompt")
        best_prompt = prompt if isinstance(prompt, str) else ""

if best_fire is not None:
    print(int(best_fire.timestamp()))
    print(best_prompt)
' 2>/dev/null || true)

if [ -z "$result" ]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

epoch=""
label=""
{
    IFS= read -r epoch
    IFS= read -r label
} <<< "$result"

if [[ ! "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$sidecar" 2>/dev/null || true
    exit 0
fi

label=$(_sanitize_and_cap "$label")

_write_sidecar "$epoch" "$label" || true

exit 0
