#!/usr/bin/env python3
"""Unit tests for bin/compute-delta.py.

Run as:  python3 test/test_compute_delta.py
Exit code 0 = all tests passed; non-zero = at least one failed (with diff).

Kept dependency-free (no pytest) so it runs in the self-test workflow
without an extra `pip install` step. The shape of these tests is the
spec for what the four-category diff guarantees — change the algorithm
and you'll break the assertions here first.
"""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import textwrap

# Import compute-delta.py by file path (it has a hyphen in the filename
# so plain `import` won't work) and exercise its `diff()` function plus
# the file-IO path through main().
ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("compute_delta", ROOT / "bin" / "compute-delta.py")
assert spec and spec.loader
compute_delta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compute_delta)


def _tsv(rows: list[tuple[str, str, str, str]]) -> str:
    return "".join("\t".join(r) + "\n" for r in rows)


def _write_pair(tmp: pathlib.Path, baseline_rows, head_rows) -> tuple[str, str, str]:
    b = tmp / "baseline.tsv"
    h = tmp / "head.tsv"
    o = tmp / "delta.json"
    b.write_text(_tsv(baseline_rows))
    h.write_text(_tsv(head_rows))
    return str(b), str(h), str(o)


def run_case(name: str, baseline_rows, head_rows, expected_totals: dict[str, int],
             extra_check=None) -> bool:
    with tempfile.TemporaryDirectory() as tmpdir:
        b, h, o = _write_pair(pathlib.Path(tmpdir), baseline_rows, head_rows)
        rc = compute_delta.main(["compute-delta.py", b, h, o])
        if rc != 0:
            print(f"  FAIL {name}: main() returned {rc}")
            return False
        result = json.loads(pathlib.Path(o).read_text())
        for k, v in expected_totals.items():
            if result["totals"].get(k) != v:
                print(f"  FAIL {name}: totals[{k!r}] expected {v}, got {result['totals'].get(k)!r}")
                print(f"       full totals: {result['totals']}")
                return False
        if extra_check is not None:
            err = extra_check(result)
            if err:
                print(f"  FAIL {name}: {err}")
                return False
        print(f"  ok   {name}")
        return True


def main() -> int:
    cases = []

    # Case 1 — pure added: head introduces a brand-new (METHOD, PATH).
    cases.append(("pure-added",
        [("GET", "/items", "items.py", "10")],
        [("GET", "/items", "items.py", "10"),
         ("POST", "/items", "items.py", "20")],
        {"baseline": 1, "head": 2, "added": 1, "removed": 0, "moved": 0, "unchanged": 1},
        lambda r: None if r["added"][0]["method"] == "POST" else "added[0] should be POST /items"))

    # Case 2 — pure removed: baseline had a route, head dropped it.
    cases.append(("pure-removed",
        [("GET", "/items", "items.py", "10"),
         ("DELETE", "/items/clear-all", "items.py", "77")],
        [("GET", "/items", "items.py", "10")],
        {"baseline": 2, "head": 1, "added": 0, "removed": 1, "moved": 0, "unchanged": 1},
        lambda r: None if r["removed"][0]["path"] == "/items/clear-all" else "removed[0] should be /items/clear-all"))

    # Case 3 — refactor: same (METHOD, PATH), different source location.
    cases.append(("refactor-moved",
        [("GET", "/items", "main.py", "31")],
        [("GET", "/items", "routers/items.py", "42")],
        {"added": 0, "removed": 0, "moved": 1, "unchanged": 0},
        lambda r: (None if r["moved"][0]["added_sites"] == [{"file": "routers/items.py", "line": "42"}]
                            and r["moved"][0]["removed_sites"] == [{"file": "main.py", "line": "31"}]
                   else "moved sub-sites wrong")))

    # Case 4 — duplicate-include defect fixed: site set shrinks 2 -> 1.
    cases.append(("duplicate-include-fixed",
        [("GET", "/dupe", "main.py", "5"),
         ("GET", "/dupe", "main.py", "6")],
        [("GET", "/dupe", "main.py", "5")],
        {"added": 0, "removed": 0, "moved": 1},
        lambda r: (None if r["moved"][0]["removed_sites"] == [{"file": "main.py", "line": "6"}]
                            and r["moved"][0]["added_sites"] == []
                   else "expected only line 6 to disappear")))

    # Case 5 — duplicate-include defect introduced: site set grows 1 -> 2.
    cases.append(("duplicate-include-introduced",
        [("GET", "/dupe", "main.py", "5")],
        [("GET", "/dupe", "main.py", "5"),
         ("GET", "/dupe", "main.py", "6")],
        {"added": 0, "removed": 0, "moved": 1},
        lambda r: (None if r["moved"][0]["added_sites"] == [{"file": "main.py", "line": "6"}]
                            and r["moved"][0]["removed_sites"] == []
                   else "expected only line 6 to appear")))

    # Case 6 — identical files (no-op PR): every row is unchanged.
    cases.append(("noop",
        [("GET", "/items", "items.py", "10"),
         ("POST", "/items", "items.py", "20")],
        [("GET", "/items", "items.py", "10"),
         ("POST", "/items", "items.py", "20")],
        {"baseline": 2, "head": 2, "added": 0, "removed": 0, "moved": 0, "unchanged": 2}))

    # Case 7 — both empty (first run on a fresh repo, no baseline yet).
    cases.append(("both-empty",
        [],
        [],
        {"baseline": 0, "head": 0, "added": 0, "removed": 0, "moved": 0, "unchanged": 0},
        lambda r: None if r["status"] == "ok" else f"status should be ok, got {r['status']!r}"))

    # Case 8 — head crashed (baseline > 0, head == 0): suppress the diff.
    cases.append(("asymmetric-head-crash",
        [("GET", "/items", "items.py", "10"),
         ("POST", "/items", "items.py", "20")],
        [],
        {"baseline": 2, "head": 0, "added": 0, "removed": 0, "moved": 0, "unchanged": 0},
        lambda r: (None if r["status"] == "suppressed-asymmetric-zero"
                   else f"status should be suppressed-asymmetric-zero, got {r['status']!r}")))

    # Case 9 — baseline crashed (head > 0, baseline == 0): suppress the diff.
    cases.append(("asymmetric-baseline-crash",
        [],
        [("GET", "/items", "items.py", "10")],
        {"baseline": 0, "head": 1, "added": 0, "removed": 0, "moved": 0, "unchanged": 0},
        lambda r: (None if r["status"] == "suppressed-asymmetric-zero"
                   else f"status should be suppressed-asymmetric-zero, got {r['status']!r}")))

    # Case 10 — different methods, same path: treated as distinct identities.
    cases.append(("methods-are-distinct",
        [("GET", "/items", "items.py", "10")],
        [("GET", "/items", "items.py", "10"),
         ("POST", "/items", "items.py", "10")],
        {"added": 1, "removed": 0, "moved": 0, "unchanged": 1},
        lambda r: None if r["added"][0]["method"] == "POST" else "POST should be the added one"))

    print(f"compute-delta unit tests: {len(cases)} cases")
    failed = 0
    for case in cases:
        if not run_case(*case):
            failed += 1
    print()
    if failed:
        print(f"FAILED: {failed}/{len(cases)} cases failed")
        return 1
    print(f"PASSED: {len(cases)}/{len(cases)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
