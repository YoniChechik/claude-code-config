#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

if [[ ! "$file_path" =~ \.md$ ]]; then
    exit 0
fi

if [ ! -f "$file_path" ]; then
    exit 0
fi

# Inline Python: format markdown tables and enforce a 240-char max width.
# stdlib-only; reads file in-place; only writes back if content changed.
python3 - "$file_path" <<'PYEOF' || true
import sys
from pathlib import Path

MAX_WIDTH = 240

def is_table_line(line: str) -> bool:
    # A markdown table line starts with '|' (after optional whitespace stripped on the right).
    return line.lstrip().startswith("|")

def parse_row(line: str):
    # Split on '|' and drop the empty first/last cells produced by leading/trailing pipes.
    s = line.strip()
    parts = s.split("|")
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return [c.strip() for c in parts]

def is_separator_cells(cells):
    # Separator cells consist solely of '-' and ':' (and must contain at least one '-').
    if not cells:
        return False
    for c in cells:
        if not c:
            return False
        if any(ch not in "-:" for ch in c):
            return False
        if "-" not in c:
            return False
    return True

def display_width(s: str) -> int:
    # Treat each character as width 1 (good enough for ASCII markdown tables).
    return len(s)

def truncate(s: str, width: int) -> str:
    # Truncate cell content to width, appending an ellipsis if shortened.
    if display_width(s) <= width:
        return s
    if width <= 1:
        return "…"[:width]
    return s[: width - 1] + "…"

def sep_cell(orig: str, width: int) -> str:
    # Re-render a separator cell preserving alignment colons.
    left = orig.startswith(":")
    right = orig.endswith(":")
    if width < 3:
        width = 3
    if left and right:
        return ":" + ("-" * (width - 2)) + ":"
    if left:
        return ":" + ("-" * (width - 1))
    if right:
        return ("-" * (width - 1)) + ":"
    return "-" * width

def format_table(rows, sep_idx, sep_orig_cells):
    # Compute number of columns from the widest row (tables can be ragged).
    num_cols = max(len(r) for r in rows)
    # Pad ragged rows with empty cells.
    rows = [r + [""] * (num_cols - len(r)) for r in rows]
    sep_orig_cells = sep_orig_cells + [""] * (num_cols - len(sep_orig_cells))

    # Compute per-column max content width across all non-separator rows.
    col_widths = [0] * num_cols
    for i, row in enumerate(rows):
        if i == sep_idx:
            continue
        for j, cell in enumerate(row):
            w = display_width(cell)
            if w > col_widths[j]:
                col_widths[j] = w

    # Each column contributes "| " + content + " ", trailing "|" once.
    # Total = sum(col_widths) + 3 * num_cols + 1.
    def total_width():
        return sum(col_widths) + 3 * num_cols + 1

    # Shrink the widest column by 1 until total fits MAX_WIDTH (or all cols at 1).
    while total_width() > MAX_WIDTH:
        widest = max(range(num_cols), key=lambda j: col_widths[j])
        if col_widths[widest] <= 1:
            break
        col_widths[widest] -= 1

    # Render each row.
    out_lines = []
    for i, row in enumerate(rows):
        if i == sep_idx:
            cells = [sep_cell(sep_orig_cells[j], col_widths[j]) for j in range(num_cols)]
        else:
            cells = [truncate(row[j], col_widths[j]).ljust(col_widths[j]) for j in range(num_cols)]
        out_lines.append("| " + " | ".join(cells) + " |")
    return out_lines

def process(text: str) -> str:
    lines = text.split("\n")
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if is_table_line(lines[i]):
            # Collect contiguous table lines.
            j = i
            while j < n and is_table_line(lines[j]):
                j += 1
            block = lines[i:j]
            rows = [parse_row(ln) for ln in block]
            # Identify separator row.
            sep_idx = -1
            for k, cells in enumerate(rows):
                if is_separator_cells(cells):
                    sep_idx = k
                    break
            if sep_idx == -1 or len(rows) < 2:
                # Not a real table; keep lines as-is.
                out.extend(block)
            else:
                sep_orig_cells = rows[sep_idx]
                formatted = format_table(rows, sep_idx, sep_orig_cells)
                out.extend(formatted)
            i = j
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out)

path = Path(sys.argv[1])
original = path.read_text()
updated = process(original)
if updated != original:
    path.write_text(updated)
PYEOF
