#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

NOISE_PREFIXES = (
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
MANUAL_COMMANDS = {"/human-meat-proxy", "/human-action-needed"}
COMMAND_RE = re.compile(r"<command-name>\s*(/[\w:-]+)\s*</command-name>")
AUTOMATION_DIR_RE = re.compile(r"-scratchpad|worktrees-agent-")
SHORT_WORDS = 25
CONTINUE_WORDS = 8
IDLE_GAP = timedelta(hours=1)
URL_RE = re.compile(r"https?://\S+")

CATEGORY_RULES = [
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
CONTINUE_RE = re.compile(
    r"^(go|cont|continue|lets? cont\w*|do it|do all|do both|fix all|fix it|fix \d"
    r"|yes|yep|ok|okay|proceed|keep going|go on|go ahead|approved|both approved"
    r"|sure|carry on|next|\d+(\s*[+,&]\s*\d+)*\s*(do|go)?)\b"
)

BUCKET_RULES = [
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
U7_RE = re.compile(
    r"session'?s? (name|scope)|scope (hasn'?t|has not|is un)changed|name (stays|still fits|is unchanged)"
)
CLAIM_RE = re.compile(r"\b(merged|deployed|is live|shipped|verified|done)\b")
TODO_HEADER_RE = re.compile(
    r"^#+\s*(todo|needs human|doing)\b", re.IGNORECASE | re.MULTILINE
)
EMPTY_SECTION_RE = re.compile(r"^[-*\d.\s]*(none|nothing|n/?a)\b", re.IGNORECASE)
STATUS_RE = re.compile(r"^STATUS: (COMPLETE|WAITING|BLOCKED|FAILURE|ANSWER)\b")


@dataclass
class Turn:
    ts: datetime
    role: str
    text: str
    command: str | None = None


@dataclass
class Session:
    path: Path
    project: str
    turns: list[Turn] = field(default_factory=list)
    interactive: bool = True


def parse_ts(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_since(raw: str, now: datetime) -> datetime:
    if m := re.fullmatch(r"(\d+)([dh])", raw):
        n = int(m.group(1))
        return now - (timedelta(days=n) if m.group(2) == "d" else timedelta(hours=n))
    parsed = datetime.fromisoformat(raw)
    return parsed if parsed.tzinfo else parsed.astimezone()


def content_text(content) -> str | None:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return None
    return "\n".join(
        b.get("text", "")
        for b in content
        if isinstance(b, dict) and b.get("type") == "text"
    )


def load_session(path: Path, since: datetime) -> Session:
    session = Session(path=path, project=path.parent.name)
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict) or entry.get("isSidechain"):
                continue
            kind = entry.get("type")
            if kind not in ("user", "assistant"):
                continue
            if kind == "user" and entry.get("entrypoint") not in (None, "cli"):
                session.interactive = False
            ts = parse_ts(entry.get("timestamp"))
            if ts is None or ts < since:
                continue
            message = entry.get("message") or {}
            if kind == "assistant":
                text = content_text(message.get("content"))
                if text and text.strip():
                    session.turns.append(Turn(ts, "assistant", text.strip()))
                continue
            if entry.get("isMeta") or entry.get("isCompactSummary"):
                continue
            text = content_text(message.get("content"))
            if not text or not text.strip():
                continue
            text = text.strip()
            if m := COMMAND_RE.search(text):
                session.turns.append(Turn(ts, "command", text, command=m.group(1)))
                continue
            if text.startswith(NOISE_PREFIXES):
                continue
            session.turns.append(Turn(ts, "human", text))
    session.turns.sort(key=lambda t: t.ts)
    return session


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", URL_RE.sub(" ", text.lower())).strip()


def classify_nudge(text: str) -> str | None:
    norm = normalize(text)
    words = norm.split()
    if len(words) > SHORT_WORDS:
        return None
    for name, rule in CATEGORY_RULES:
        if rule.search(norm):
            return name
    if len(words) <= CONTINUE_WORDS and CONTINUE_RE.match(norm):
        return "continue"
    return None


def classify_buckets(prev: str, category: str) -> list[str]:
    tail = normalize(prev[-2000:])
    buckets = [name for name, rule in BUCKET_RULES if rule.search(tail)]
    if len(prev) < 400 and U7_RE.search(tail):
        buckets.insert(0, "U7-filler-final")
    if category in ("verify", "done-check") and CLAIM_RE.search(tail):
        buckets.append("U3-done-without-check")
    if not buckets and prev.rstrip().endswith("?"):
        buckets.append("U1-permission-ask")
    return buckets or ["unclassified"]


def has_open_todo(text: str) -> bool:
    headers = list(TODO_HEADER_RE.finditer(text))
    for m in headers:
        end = text.find("\n#", m.end())
        body = text[m.end() : end if end != -1 else len(text)].strip()
        if body and not EMPTY_SECTION_RE.match(body):
            return True
    tail = normalize(text[-2000:])
    return any(
        rule.search(tail)
        for name, rule in BUCKET_RULES
        if name.startswith(("U2", "U4", "U5"))
    )


def ends_with_status(text: str) -> bool:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return bool(lines) and bool(STATUS_RE.match(lines[-1]))


def clip(text: str, n: int = 240) -> str:
    flat = re.sub(r"\s+", " ", text).strip()
    return flat if len(flat) <= n else flat[: n - 3] + "..."


def analyze(sessions: list[Session]) -> dict:
    nudges = []
    idle_gaps = []
    human_turns = 0
    final_total = 0
    final_with_status = 0
    for s in sessions:
        prev: Turn | None = None
        for turn in s.turns:
            if turn.role == "assistant":
                prev = turn
                continue
            category = None
            if turn.role == "command":
                if turn.command not in MANUAL_COMMANDS:
                    continue
                category = "manual-proxy"
            human_turns += 1
            if prev is not None:
                final_total += 1
                final_with_status += ends_with_status(prev.text)
            category = category or classify_nudge(turn.text)
            gap = turn.ts - prev.ts if prev else None
            if prev is not None and gap and gap > IDLE_GAP and has_open_todo(prev.text):
                idle_gaps.append(
                    {
                        "session": s.path.stem,
                        "project": s.project,
                        "assistant_ts": prev.ts.isoformat(),
                        "human_ts": turn.ts.isoformat(),
                        "gap_hours": round(gap.total_seconds() / 3600, 2),
                        "human": clip(turn.text, 160),
                        "assistant_tail": clip(prev.text[-600:]),
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
                    "buckets": classify_buckets(prev.text, category)
                    if prev
                    else ["unclassified"],
                    "text": clip(turn.text, 160),
                    "prev_tail": clip(prev.text[-600:]) if prev else "",
                }
            )
        if prev is not None and s.turns and s.turns[-1] is prev:
            final_total += 1
            final_with_status += ends_with_status(prev.text)

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


def render_text(report: dict) -> str:
    out = [
        f"Window: {report['window']['since']} .. {report['window']['until']}",
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
        "--json", action="store_true", help="print the full report as JSON"
    )
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    try:
        since = parse_since(args.since, now)
    except ValueError:
        parser.error(f"invalid --since: {args.since}")
    if not args.projects_dir.is_dir():
        parser.error(f"not a directory: {args.projects_dir}")

    cutoff = since.timestamp()
    sessions = []
    for path in sorted(args.projects_dir.glob("*/*.jsonl")):
        if AUTOMATION_DIR_RE.search(path.parent.name) or path.stat().st_mtime < cutoff:
            continue
        session = load_session(path, since)
        if session.interactive and any(
            t.role in ("human", "command") for t in session.turns
        ):
            sessions.append(session)

    report = {
        "window": {"since": since.isoformat(), "until": now.isoformat()},
        **analyze(sessions),
    }
    print(
        json.dumps(report, indent=2, ensure_ascii=False)
        if args.json
        else render_text(report)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
