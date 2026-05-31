#!/usr/bin/env python3
"""Compute a structural diff between two endpoints.tsv files.

Each row is  METHOD \\t PATH \\t SOURCE_FILE \\t SOURCE_LINE  as produced by
bin/parse-endpoints.py. The diff is a multi-set diff over (METHOD, PATH)
keys with set-of-(FILE, LINE) values:

  - added       : (METHOD, PATH) present in HEAD but absent in BASELINE
                  -> the PR introduces a new public route surface
  - removed     : (METHOD, PATH) present in BASELINE but absent in HEAD
                  -> the PR drops a route from the public surface
  - moved       : (METHOD, PATH) in both, but the set of (FILE, LINE)
                  registration sites differs -> typically a refactor moving
                  the registration across modules; the most interesting
                  sub-case is "sites set shrank by 1" -> a duplicate-include
                  defect was fixed (or "sites set grew by 1" -> one was
                  introduced)
  - unchanged   : (METHOD, PATH) in both with identical site sets

A baseline analysis that crashed (head_count > 0, baseline_count == 0) or a
head analysis that crashed (baseline_count > 0, head_count == 0) would
otherwise produce nonsense deltas. The script detects both and refuses
the diff with status == "suppressed-asymmetric-zero" so downstream
consumers can render a clear "delta unavailable, analyzer asymmetry"
message instead of a wall of fake additions/removals.

Usage:  compute-delta.py <baseline.tsv> <head.tsv> <delta.json>
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from typing import Any


Site = tuple[str, str]                    # (file, line)
Key = tuple[str, str]                     # (method, path)
Index = dict[Key, set[Site]]


def _read_tsv(path: str) -> Index:
    """Read a 4-column endpoints.tsv into {(method, path): {(file, line), ...}}.

    Returns an empty index if the file is missing or empty — both happen
    legitimately (no baseline on first PR; head analysis crashed).
    """
    idx: Index = defaultdict(set)
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) != 4:
                    # Skip malformed rows rather than abort the diff —
                    # parse-endpoints.py only writes 4-col rows, so a row
                    # with a different shape comes from an older analyzer
                    # version (e.g., a stale cache from before a column
                    # was added). Drop it.
                    continue
                method, path, fpath, fline = parts
                idx[(method, path)].add((fpath, fline))
    except FileNotFoundError:
        pass
    return idx


def _sorted_sites(sites: set[Site]) -> list[dict[str, str]]:
    """Render a site set as a list of {file, line} dicts, sorted for stable
    JSON output (file asc, then line numerically asc when both sides are
    digits, else lexically).
    """
    def key(site: Site) -> tuple[str, int, str]:
        fpath, fline = site
        try:
            return (fpath, int(fline), fline)
        except ValueError:
            return (fpath, 0, fline)
    return [{"file": f, "line": l} for f, l in sorted(sites, key=key)]


def diff(baseline: Index, head: Index) -> dict[str, Any]:
    """Compute the four-category delta. Output schema is documented inline
    so changes here are obvious in code review."""
    baseline_count = sum(len(v) for v in baseline.values())
    head_count = sum(len(v) for v in head.values())

    # Asymmetric-zero suppression: if one side has zero endpoints and the
    # other doesn't, the analysis pipeline broke on one side and the diff
    # would be a wall of phantom changes. Return a stub with status set
    # so the renderer can show a clear failure rather than dump 287
    # "removed" rows.
    if (baseline_count == 0) != (head_count == 0) and (baseline_count + head_count) > 0:
        return {
            "status": "suppressed-asymmetric-zero",
            "totals": {
                "baseline": baseline_count,
                "head": head_count,
                "added": 0,
                "removed": 0,
                "moved": 0,
                "unchanged": 0,
            },
            "added": [],
            "removed": [],
            "moved": [],
            "unchanged_count": 0,
        }

    baseline_keys = set(baseline.keys())
    head_keys = set(head.keys())

    added_keys = head_keys - baseline_keys
    removed_keys = baseline_keys - head_keys
    common_keys = baseline_keys & head_keys

    # Within `added` / `removed`, expand the site set into one entry per
    # site so a brand-new route registered from two files shows as two
    # rows. The renderer can fold these by key if desired.
    added: list[dict[str, Any]] = []
    for k in added_keys:
        method, path = k
        for site in _sorted_sites(head[k]):
            added.append({"method": method, "path": path, **site})

    removed: list[dict[str, Any]] = []
    for k in removed_keys:
        method, path = k
        for site in _sorted_sites(baseline[k]):
            removed.append({"method": method, "path": path, **site})

    moved: list[dict[str, Any]] = []
    unchanged_count = 0
    for k in common_keys:
        b_sites = baseline[k]
        h_sites = head[k]
        if b_sites == h_sites:
            unchanged_count += len(b_sites)
            continue
        # Site set differs. Decompose into added_sites / removed_sites so
        # the renderer can distinguish "moved across files" from "got a
        # new duplicate registration" / "lost a duplicate registration".
        method, path = k
        moved.append({
            "method": method,
            "path": path,
            "from": _sorted_sites(b_sites),
            "to": _sorted_sites(h_sites),
            "added_sites": _sorted_sites(h_sites - b_sites),
            "removed_sites": _sorted_sites(b_sites - h_sites),
        })

    def sort_key(row: dict[str, Any]) -> tuple[str, str]:
        return (row["method"], row["path"])

    added.sort(key=sort_key)
    removed.sort(key=sort_key)
    moved.sort(key=sort_key)

    return {
        "status": "ok",
        "totals": {
            "baseline": baseline_count,
            "head": head_count,
            "added": len(added),
            "removed": len(removed),
            "moved": len(moved),
            "unchanged": unchanged_count,
        },
        "added": added,
        "removed": removed,
        "moved": moved,
        "unchanged_count": unchanged_count,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(f"usage: {argv[0]} <baseline.tsv> <head.tsv> <delta.json>", file=sys.stderr)
        return 2
    baseline_path, head_path, out_path = argv[1], argv[2], argv[3]
    baseline = _read_tsv(baseline_path)
    head = _read_tsv(head_path)
    result = diff(baseline, head)
    with open(out_path, "w") as fh:
        json.dump(result, fh, indent=2)
    t = result["totals"]
    print(
        f"delta: status={result['status']} "
        f"baseline={t['baseline']} head={t['head']} "
        f"+{t['added']} -{t['removed']} ~{t['moved']} "
        f"unchanged={t['unchanged']} -> {out_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
