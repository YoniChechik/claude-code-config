#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from _transcript import ReadStats, is_tool_result, main_thread_records, text_of

_COORDINATOR = Path(__file__).resolve().parent / "stop__coordinator.sh"
_LOG_RE = re.compile(
    r"\b(?:block \d+/\d+ rules=(?P<rules>\S+)|pass) session=(?P<sid>replay-\d+)\b"
)


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Replay historical final assistant messages through the Stop gate and count would-block verdicts."
    )
    p.add_argument(
        "--days", type=float, default=2.0, help="look back this many days (default 2)"
    )
    p.add_argument(
        "--projects-dir", type=Path, default=Path.home() / ".claude" / "projects"
    )
    p.add_argument(
        "--samples", type=int, default=3, help="example messages printed per rule"
    )
    p.add_argument(
        "--limit",
        type=int,
        default=0,
        help="stop after this many final messages (0 = all)",
    )
    return p.parse_args()


def _final_messages(path: Path, stats: ReadStats):
    last_text = ""
    last_ts = ""
    for rec in main_thread_records(path, stats):
        kind = rec.get("type")
        msg = rec.get("message") or {}
        content = msg.get("content")
        if kind == "assistant":
            t = text_of(content).strip()
            if t:
                last_text = t
                last_ts = rec["timestamp"]
        elif kind == "user" and not is_tool_result(content):
            if last_text:
                yield last_ts, last_text
            last_text = ""
    if last_text:
        yield last_ts, last_text


def main() -> int:
    args = _parse_args()
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    files = sorted(
        f
        for f in args.projects_dir.rglob("*.jsonl")
        if "subagents" not in f.parts
        and datetime.fromtimestamp(f.stat().st_mtime, timezone.utc) >= cutoff
    )
    stats = ReadStats()
    stops = []
    for f in files:
        for ts, text in _final_messages(f, stats):
            if ts < cutoff.isoformat():
                continue
            stops.append((f, ts, text))
            if args.limit and len(stops) >= args.limit:
                break
        if args.limit and len(stops) >= args.limit:
            break
    if not stops:
        print("no final messages found")
        return 0

    with tempfile.TemporaryDirectory(prefix="done_gate_replay.") as tmp:
        env = os.environ | {
            "CLAUDE_STATE_DIR": f"{tmp}/state",
            "CLAUDE_HOOK_LOG_DIR": f"{tmp}/logs",
            "CLAUDE_NOTIFY_TMP_DIR": f"{tmp}/notify",
            "CLAUDE_HOOK_LOG_MAX_BYTES": str(1 << 40),
        }
        os.makedirs(env["CLAUDE_NOTIFY_TMP_DIR"])
        for i, (_, _, text) in enumerate(stops):
            payload = {
                "hook_event_name": "Stop",
                "session_id": f"replay-{i}",
                "stop_hook_active": False,
                "last_assistant_message": text,
                "background_tasks": [],
                "session_crons": [],
            }
            subprocess.run(
                ["bash", str(_COORDINATOR)],
                input=json.dumps(payload),
                text=True,
                env=env,
                capture_output=True,
                check=False,
            )
        log = Path(env["CLAUDE_HOOK_LOG_DIR"], "hooks.log").read_text(
            encoding="utf-8", errors="replace"
        )

    verdicts: dict[int, list[str]] = {}
    for m in _LOG_RE.finditer(log):
        idx = int(m.group("sid").split("-")[1])
        verdicts[idx] = m.group("rules").split(",") if m.group("rules") else []

    per_rule = Counter()
    per_day = defaultdict(lambda: [0, 0])
    samples = defaultdict(list)
    blocked = 0
    for i, (f, ts, text) in enumerate(stops):
        rules = verdicts.get(i)
        day = ts[:10]
        per_day[day][0] += 1
        if rules is None:
            per_rule["(no verdict logged)"] += 1
            continue
        if rules:
            blocked += 1
            per_day[day][1] += 1
        for r in rules:
            per_rule[r] += 1
            if len(samples[r]) < args.samples:
                last = [ln for ln in text.splitlines() if ln.strip()][-1]
                samples[r].append(
                    f"{f.parent.name}/{f.stem[:8]} {ts[:16]}: {last[:160]}"
                )

    total = len(stops)
    print(
        f"Replayed {total} final messages from {len(files)} transcripts (last {args.days:g} days)."
    )
    print(f"Unparseable transcript lines skipped: {stats.bad_lines}")
    print(
        "Only G1 and G3 are meaningful here: historical sessions have no ledger, so G2 and G4 never fire."
    )
    print(
        f"Would block: {blocked} ({blocked * 100 / total:.1f}%)   would pass: {total - blocked}"
    )
    print("\nPer rule:")
    for rule, n in sorted(per_rule.items()):
        print(f"  {rule}: {n} ({n * 100 / total:.1f}%)")
    print("\nPer day (stops / would block):")
    for day in sorted(per_day):
        n, b = per_day[day]
        print(f"  {day}: {n} / {b}")
    for rule in sorted(samples):
        print(f"\nExamples for {rule} (last line):")
        for s in samples[rule]:
            print(f"  - {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
