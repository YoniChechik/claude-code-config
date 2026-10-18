#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

from _transcript import ReadStats, is_tool_result, main_thread_records, text_of

_NOISE_PREFIXES = (
    "<task-notification",
    "<local-command",
    "<bash-input",
    "<bash-stdout",
    "<bash-stderr",
    "<system-reminder",
    "[Request interrupted",
    "Caveat:",
    "!",
)
_MANUAL_COMMANDS = {"/human-meat-proxy", "/human-action-needed"}
_COMMAND_RE = re.compile(r"<command-name>\s*(/[\w:-]+)\s*</command-name>")
_AUTOMATION_DIR_RE = re.compile(r"-scratchpad|worktrees-agent-")
_SHORT_WORDS = 25
_CONTINUE_WORDS = 8
_IDLE_GAP = timedelta(hours=1)
_URL_RE = re.compile(r"https?://\S+")

_CATEGORY_RULES = [
    ("admin", re.compile(r"why (is )?admin|--admin|admin (merge )?needed")),
    (
        "stall",
        re.compile(
            r"why (are you |r u |is it |did you )?(hang|stuck|stop|idle|wait)"
            r"|hanging|\bstall|why didn'?t you (ci-?watch|watch|wait|poll|continue|monitor)"
            r"|still waiting\?|clear (data|dockers?|sims)|free up"
        ),
    ),
    (
        "done-check",
        re.compile(
            r"all done\??|(is|are) (it|we|this|that|they) done|not done\?"
            r"|why unmigrated|anything (else )?left|what('?s| is) left"
            r"|is the code good|secure\?|other th[ae]n this"
        ),
    ),
    (
        "verify",
        re.compile(
            r"\bverif|\bvalidat|can we (test|check|do it on staging|do it on)"
            r"|how can we (check|test)|did you (check|test|run|look)"
            r"|\bref\?|is it (live|deployed|working)\?|test (it|on|this)"
        ),
    ),
    (
        "do-yourself",
        re.compile(
            r"yourself|with chrome mcp|use chrome|go to gmail"
            r"|you can do (it|this)|do one that you can|you have (access|chrome)"
            r"|can'?t you (do|check|run|fix)|why (do|should) i\b"
        ),
    ),
]
_CONTINUE_RE = re.compile(
    r"^(go|cont|continue|lets? cont\w*|do it|do all|do both|fix all|fix it|fix \d"
    r"|yes|yep|ok|okay|proceed|keep going|go on|go ahead|approved|both approved"
    r"|sure|carry on|next|\d+(\s*[+,&]\s*\d+)*\s*(do|go)?)\b"
)

_BUCKET_RULES = [
    ("U6-admin-handoff", re.compile(r"--admin")),
    (
        "U5-idle-waiting",
        re.compile(
            r"waiting (for|on) (you|your)|nothing is running|i will not poll"
            r"|i won'?t poll|can'?t poll|unless you say otherwise|still waiting"
        ),
    ),
    (
        "U4-verify-pushed-away",
        re.compile(
            r"once (real )?users|check (them|it|back) (in|tomorrow)|ask me later"
            r"|tell me when|run (it|this) yourself|please run|in a (normal|new) terminal"
            r"|when the stores approve|you (need|have) to (run|check|open|paste)"
        ),
    ),
    (
        "U1-permission-ask",
        re.compile(
            r"do you want me|want me to|should i\b|shall i|say the word|tell me if"
            r"|if you want|which (option|one|account)|\bdecid|\bdecision needed|i recommend"
            r"|your call|go-ahead|say if you"
        ),
    ),
    (
        "U2-listed-todo-stopped",
        re.compile(
            r"haven'?t (confirmed|checked|done|verified|opened|run)"
            r"|didn'?t (check|confirm|verify|run|open)|not (yet )?(tested|verified|checked)"
        ),
    ),
    (
        "U8-hid-symptom",
        re.compile(r"only a console warning|suppress|downgrad|i meant|silenc"),
    ),
]
_U7_RE = re.compile(
    r"session'?s? (name|scope)|scope (hasn'?t|has not|is un)changed|name (stays|still fits|is unchanged)"
)
_CLAIM_RE = re.compile(r"\b(merged|deployed|is live|shipped|verified|done)\b")
_TODO_HEADER_RE = re.compile(
    r"^#+\s*(todo|needs human|doing)\b", re.IGNORECASE | re.MULTILINE
)
_EMPTY_SECTION_RE = re.compile(r"^[-*\d.\s]*(none|nothing|n/?a)\b", re.IGNORECASE)
_STATUS_RE = re.compile(r"^STATUS: (COMPLETE|WAITING|BLOCKED|FAILURE|ANSWER)\b")
_MISSING_PATH_BINS = {"ls", "test", "stat", "cat"}
_REPEAT_LIMIT = 3


@dataclass
class _Turn:
    ts: datetime
    role: str
    text: str
    command: str | None = None


@dataclass
class _Session:
    path: Path
    project: str
    turns: list[_Turn] = field(default_factory=list)
    interactive: bool = True


def _parse_ts(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def _parse_since(raw: str, now: datetime) -> datetime:
    if m := re.fullmatch(r"(\d+)([dh])", raw):
        n = int(m.group(1))
        return now - (timedelta(days=n) if m.group(2) == "d" else timedelta(hours=n))
    parsed = datetime.fromisoformat(raw)
    return parsed if parsed.tzinfo else parsed.astimezone()


def _content_text(content) -> str | None:
    if not isinstance(content, (str, list)) or is_tool_result(content):
        return None
    return text_of(content)


def _load_session(path: Path, since: datetime, stats: ReadStats) -> _Session:
    session = _Session(path=path, project=path.parent.name)
    for entry in main_thread_records(path, stats):
        kind = entry.get("type")
        if kind not in ("user", "assistant"):
            continue
        if kind == "user" and entry.get("entrypoint") not in (None, "cli"):
            session.interactive = False
        ts = _parse_ts(entry.get("timestamp"))
        if ts is None or ts < since:
            continue
        message = entry.get("message") or {}
        if kind == "assistant":
            text = _content_text(message.get("content"))
            if text and text.strip():
                session.turns.append(_Turn(ts, "assistant", text.strip()))
            continue
        if entry.get("isMeta") or entry.get("isCompactSummary"):
            continue
        text = _content_text(message.get("content"))
        if not text or not text.strip():
            continue
        text = text.strip()
        if m := _COMMAND_RE.search(text):
            session.turns.append(_Turn(ts, "command", text, command=m.group(1)))
            continue
        if text.startswith(_NOISE_PREFIXES):
            continue
        session.turns.append(_Turn(ts, "human", text))
    session.turns.sort(key=lambda t: t.ts)
    return session


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", _URL_RE.sub(" ", text.lower())).strip()


def _classify_nudge(text: str) -> str | None:
    norm = _normalize(text)
    words = norm.split()
    if len(words) > _SHORT_WORDS:
        return None
    for name, rule in _CATEGORY_RULES:
        if rule.search(norm):
            return name
    if len(words) <= _CONTINUE_WORDS and _CONTINUE_RE.match(norm):
        return "continue"
    return None


def _classify_buckets(prev: str, category: str) -> list[str]:
    tail = _normalize(prev[-2000:])
    buckets = [name for name, rule in _BUCKET_RULES if rule.search(tail)]
    if len(prev) < 400 and _U7_RE.search(tail):
        buckets.insert(0, "U7-filler-final")
    if category in ("verify", "done-check") and _CLAIM_RE.search(tail):
        buckets.append("U3-done-without-check")
    if not buckets and prev.rstrip().endswith("?"):
        buckets.append("U1-permission-ask")
    return buckets or ["unclassified"]


def _has_open_todo(text: str) -> bool:
    headers = list(_TODO_HEADER_RE.finditer(text))
    for m in headers:
        end = text.find("\n#", m.end())
        body = text[m.end() : end if end != -1 else len(text)].strip()
        if body and not _EMPTY_SECTION_RE.match(body):
            return True
    tail = _normalize(text[-2000:])
    return any(
        rule.search(tail)
        for name, rule in _BUCKET_RULES
        if name.startswith(("U2", "U4", "U5"))
    )


def _ends_with_status(text: str) -> bool:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return bool(lines) and bool(_STATUS_RE.match(lines[-1]))


def _clip(text: str, n: int = 240) -> str:
    flat = re.sub(r"\s+", " ", text).strip()
    return flat if len(flat) <= n else flat[: n - 3] + "..."


def _analyze(sessions: list[_Session]) -> dict:
    nudges = []
    idle_gaps = []
    human_turns = 0
    final_total = 0
    final_with_status = 0
    for s in sessions:
        prev: _Turn | None = None
        for turn in s.turns:
            if turn.role == "assistant":
                prev = turn
                continue
            category = None
            if turn.role == "command":
                if turn.command not in _MANUAL_COMMANDS:
                    continue
                category = "manual-proxy"
            human_turns += 1
            if prev is not None:
                final_total += 1
                final_with_status += _ends_with_status(prev.text)
            category = category or _classify_nudge(turn.text)
            gap = turn.ts - prev.ts if prev else None
            if (
                prev is not None
                and gap
                and gap > _IDLE_GAP
                and _has_open_todo(prev.text)
            ):
                idle_gaps.append(
                    {
                        "session": s.path.stem,
                        "project": s.project,
                        "assistant_ts": prev.ts.isoformat(),
                        "human_ts": turn.ts.isoformat(),
                        "gap_hours": round(gap.total_seconds() / 3600, 2),
                        "human": _clip(turn.text, 160),
                        "assistant_tail": _clip(prev.text[-600:]),
                    }
                )
            if category is None:
                continue
            nudges.append(
                {
                    "session": s.path.stem,
                    "project": s.project,
                    "ts": turn.ts.isoformat(),
                    "day": turn.ts.astimezone().date().isoformat(),
                    "category": category,
                    "buckets": _classify_buckets(prev.text, category)
                    if prev
                    else ["unclassified"],
                    "text": _clip(turn.text, 160),
                    "prev_tail": _clip(prev.text[-600:]) if prev else "",
                }
            )
        if prev is not None and s.turns and s.turns[-1] is prev:
            final_total += 1
            final_with_status += _ends_with_status(prev.text)

    by_day: dict[str, dict] = defaultdict(
        lambda: {"total": 0, "categories": Counter(), "buckets": Counter()}
    )
    for n in nudges:
        day = by_day[n["day"]]
        day["total"] += 1
        day["categories"][n["category"]] += 1
        day["buckets"][n["buckets"][0]] += 1
    active_days = sorted(
        {
            t.ts.astimezone().date().isoformat()
            for s in sessions
            for t in s.turns
            if t.role == "human"
        }
    )
    return {
        "sessions": len(sessions),
        "human_turns": human_turns,
        "nudges_total": len(nudges),
        "active_days": len(active_days),
        "nudges_per_active_day": round(len(nudges) / len(active_days), 1)
        if active_days
        else 0.0,
        "by_category": dict(Counter(n["category"] for n in nudges).most_common()),
        "by_bucket": dict(
            Counter(b for n in nudges for b in n["buckets"]).most_common()
        ),
        "by_primary_bucket": dict(
            Counter(n["buckets"][0] for n in nudges).most_common()
        ),
        "by_day": {
            d: {
                "total": v["total"],
                "categories": dict(v["categories"]),
                "buckets": dict(v["buckets"]),
            }
            for d, v in sorted(by_day.items())
        },
        "final_messages": {
            "total": final_total,
            "with_status_line": final_with_status,
            "missing_status_rate": round(1 - final_with_status / final_total, 3)
            if final_total
            else 0.0,
        },
        "idle_gaps": sorted(idle_gaps, key=lambda g: -g["gap_hours"]),
        "nudges": nudges,
    }


def _record_ts(raw) -> datetime | None:
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        try:
            return datetime.fromtimestamp(raw, UTC)
        except OverflowError, OSError, ValueError:
            return None
    if isinstance(raw, str):
        ts = _parse_ts(raw)
        return ts if ts is None or ts.tzinfo else ts.astimezone()
    return None


def _load_failures(
    state_dir: Path, since: datetime, stats: ReadStats
) -> list[tuple[str, datetime, dict]]:
    failures = []
    for path in sorted(state_dir.glob("sessions/*/ledger.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    stats.bad_lines += 1
                    continue
                if not isinstance(rec, dict):
                    stats.bad_lines += 1
                    continue
                if rec.get("kind") != "failure":
                    continue
                ts = _record_ts(rec.get("ts"))
                if ts is None or ts < since:
                    continue
                failures.append((path.parent.name, ts, rec))
    return failures


def _verdict(rec: dict) -> str:
    if rec.get("capped") is True:
        return "capped"
    if rec.get("exempt") is not None:
        return "exempt"
    return "accepted" if rec.get("accepted") is True else "rejected"


def _ladder_flags(rec: dict, verdict: str) -> list[str]:
    attempts = [a for a in rec.get("attempts") or [] if isinstance(a, dict)]
    cmds = [str(a.get("cmd", "")) for a in attempts]
    flags = []
    if cmds:
        cmd, count = Counter(cmds).most_common(1)[0]
        if count >= _REPEAT_LIMIT:
            flags.append(f"a: one cmd repeated {count}x ({_clip(cmd, 80)})")
    if attempts and all(
        "No such file or directory" in str(a.get("out_excerpt") or "")
        and a.get("bin") in _MISSING_PATH_BINS
        for a in attempts
    ):
        flags.append("b: every attempt is a missing-path probe")
    if verdict == "capped":
        distinct_cmds = len(set(cmds))
        distinct_bins = len({a.get("bin") for a in attempts})
        n_attempts = rec.get("n_attempts") or 0
        n_approaches = rec.get("n_approaches") or 0
        if distinct_cmds < n_attempts or distinct_bins < n_approaches:
            flags.append(
                f"c: {distinct_cmds} distinct cmds / {distinct_bins} distinct bins"
                f" below claimed {n_attempts} attempts / {n_approaches} approaches"
            )
    return flags


def _analyze_failures(failures: list[tuple[str, datetime, dict]]) -> dict:
    by_verdict = Counter({"accepted": 0, "rejected": 0, "exempt": 0, "capped": 0})
    trivial = []
    for session, ts, rec in failures:
        verdict = _verdict(rec)
        by_verdict[verdict] += 1
        if verdict not in ("accepted", "capped"):
            continue
        if flags := _ladder_flags(rec, verdict):
            trivial.append(
                {
                    "session": session,
                    "ts": ts.isoformat(),
                    "verdict": verdict,
                    "what": _clip(str(rec.get("what") or ""), 160),
                    "reason": "; ".join(flags),
                    "cmds": [
                        str(a.get("cmd", ""))
                        for a in rec.get("attempts") or []
                        if isinstance(a, dict)
                    ],
                }
            )
    return {
        "failures": {"total": len(failures), "by_verdict": dict(by_verdict)},
        "trivial_ladders": trivial,
    }


def _render_text(report: dict) -> str:
    out = [
        f"Window: {report['window']['since']} .. {report['window']['until']}",
        f"Unparseable transcript lines skipped: {report['unparseable_lines']}",
        f"Sessions: {report['sessions']}  human turns: {report['human_turns']}",
        (
            f"Nudges: {report['nudges_total']}  active days: {report['active_days']}"
            f"  per active day: {report['nudges_per_active_day']}"
        ),
        "",
        "By category:",
        *(f"  {k}: {v}" for k, v in report["by_category"].items()),
        "",
        "By primary bucket:",
        *(f"  {k}: {v}" for k, v in report["by_primary_bucket"].items()),
        "",
        "Per day:",
        *(
            f"  {d}: {v['total']}  "
            + ", ".join(f"{k}={c}" for k, c in sorted(v["categories"].items()))
            for d, v in report["by_day"].items()
        ),
        "",
        (
            f"Final messages: {report['final_messages']['total']}"
            f"  with STATUS line: {report['final_messages']['with_status_line']}"
            f"  missing rate: {report['final_messages']['missing_status_rate']}"
        ),
        "",
        f"Idle gaps over 1h after an open TODO: {len(report['idle_gaps'])}",
        *(
            f"  {g['gap_hours']}h {g['project']}/{g['session'][:8]} {g['assistant_ts']} -> {g['human']}"
            for g in report["idle_gaps"][:15]
        ),
        "",
        "FAILURE ladders:",
        f"  Unparseable ledger lines skipped: {report['unparseable_ledger_lines']}",
        (
            f"  Total: {report['failures']['total']}  "
            + ", ".join(f"{k}={v}" for k, v in report["failures"]["by_verdict"].items())
        ),
        f"  Trivial ladders: {len(report['trivial_ladders'])}",
        *(
            f"    {t['session']} {t['ts']} [{t['verdict']}] {t['what']}\n"
            f"      reason: {t['reason']}\n"
            f"      cmds: {' | '.join(t['cmds'])}"
            for t in report["trivial_ladders"]
        ),
    ]
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Count human nudges in Claude Code main-thread transcripts."
    )
    parser.add_argument(
        "--since", default="7d", help="Nd, Nh, or an ISO date/datetime (default 7d)"
    )
    parser.add_argument(
        "--projects-dir", type=Path, default=Path.home() / ".claude" / "projects"
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path(
            os.environ.get("CLAUDE_STATE_DIR") or Path.home() / ".claude" / "state"
        ),
        help="hook state dir holding sessions/*/ledger.jsonl",
    )
    parser.add_argument(
        "--json", action="store_true", help="print the full report as JSON"
    )
    args = parser.parse_args()

    now = datetime.now(UTC)
    try:
        since = _parse_since(args.since, now)
    except ValueError:
        parser.error(f"invalid --since: {args.since}")
    if not args.projects_dir.is_dir():
        parser.error(f"not a directory: {args.projects_dir}")

    cutoff = since.timestamp()
    stats = ReadStats()
    sessions = []
    for path in sorted(args.projects_dir.glob("*/*.jsonl")):
        if _AUTOMATION_DIR_RE.search(path.parent.name) or path.stat().st_mtime < cutoff:
            continue
        session = _load_session(path, since, stats)
        if session.interactive and any(
            t.role in ("human", "command") for t in session.turns
        ):
            sessions.append(session)

    ledger_stats = ReadStats()
    failures = _load_failures(args.state_dir, since, ledger_stats)

    report = {
        "window": {"since": since.isoformat(), "until": now.isoformat()},
        "unparseable_lines": stats.bad_lines,
        "unparseable_ledger_lines": ledger_stats.bad_lines,
        **_analyze(sessions),
        **_analyze_failures(failures),
    }
    print(
        json.dumps(report, indent=2, ensure_ascii=False)
        if args.json
        else _render_text(report)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
