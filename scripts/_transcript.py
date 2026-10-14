import json
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ReadStats:
    bad_lines: int = 0


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def is_tool_result(content) -> bool:
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def main_thread_records(path: Path, stats: ReadStats) -> Iterator[dict]:
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                stats.bad_lines += 1
                continue
            if isinstance(rec, dict) and not rec.get("isSidechain"):
                yield rec
