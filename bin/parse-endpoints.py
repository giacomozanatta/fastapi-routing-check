#!/usr/bin/env python3
"""Extract the recovered HTTP endpoints from a lisa-network final-network.txt
into a tab-separated table.

Output rows are:  METHOD \\t PATH \\t SOURCE_FILE \\t SOURCE_LINE

Consumed by:
  - the head analysis (rendering the endpoint inventory in the sticky PR
    comment and the workflow job summary)
  - the merge-base analysis (the baseline half of the endpoint-delta
    computation in compute-delta.py)

Both call sites need the same parser, so it lives here rather than inline in
entrypoint.sh — keeping a single source of truth for what counts as an
endpoint row across baseline vs head, which the diff would otherwise blame
on the codebase.

Usage:  parse-endpoints.py <path/to/final-network.txt> <path/to/endpoints.tsv>
"""
import re
import sys

# Section structure in final-network.txt:
#   COUNT: N
#   GET: K
#       /api/v1/items/featured: app/main.py:22:25
#       /api/v1/items/{item_id}: app/main.py:22:25
#   POST: M
#       ...
#   (blank line ends the endpoint section; the rest of the file holds
#    unrelated UNREACHABLE ROUTES / DUPLICATE include_router REGISTRATIONS
#    sections that this parser intentionally ignores.)
METHOD_RE = re.compile(r"^([A-Z]+):\s*\d+\s*$")
ENDPOINT_RE = re.compile(r"^\s+(\S.+?):\s*(?:/workspace/)?([\S][^\s:'\"]*\.py):(\d+):\d+\s*$")


def parse(final_txt_path: str) -> list[tuple[str, str, str, str]]:
    rows: list[tuple[str, str, str, str]] = []
    seen: set[tuple[str, str, str, str]] = set()  # de-dup identical lines
    current_method: str | None = None
    with open(final_txt_path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                if current_method is not None:
                    # Blank line after we entered the listing -> end of section.
                    break
                continue
            m = METHOD_RE.match(line)
            if m:
                current_method = m.group(1)
                continue
            if current_method is None:
                continue
            em = ENDPOINT_RE.match(line)
            if not em:
                continue
            path = em.group(1).strip()
            fpath = em.group(2)
            fline = em.group(3)
            key = (current_method, path, fpath, fline)
            if key in seen:
                continue
            seen.add(key)
            rows.append(key)
    return rows


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <final-network.txt> <endpoints.tsv>", file=sys.stderr)
        return 2
    in_path, out_path = argv[1], argv[2]
    rows = parse(in_path)
    with open(out_path, "w") as fh:
        for r in rows:
            fh.write("\t".join(r) + "\n")
    print(f"parsed {len(rows)} endpoints -> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
