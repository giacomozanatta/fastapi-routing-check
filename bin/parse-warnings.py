#!/usr/bin/env python3
"""Parse lisa-network's report.json into the action's downstream artefacts:

  - findings.tsv  (always)  — tab-separated rows consumed by entrypoint.sh's
                              sticky-comment + job-summary + annotation
                              emitters, plus the new-finding diff path.
                              6 columns:  NEW \\t SEV \\t FAM \\t FILE \\t LINE \\t TITLE
                              where NEW is the literal string "NEW" if the
                              finding identity is not present in the baseline
                              findings file (when --baseline-findings is
                              given), otherwise an empty string.
  - results.sarif (optional) — SARIF 2.1.0 with the rule catalogue and one
                              result per finding. Skipped when --sarif is
                              not provided (baseline analysis doesn't need
                              it; only head does).

Shared by:
  - entrypoint.sh: head analysis. Passes --baseline-findings so the head
    TSV gets the NEW column populated.
  - bin/run-baseline-analysis.sh: merge-base analysis. No --baseline-findings
    (a baseline doesn't have a baseline-of-its-own), no --sarif.

Single parser → no drift risk on the new-finding classification: a finding
that the head parser would classify as wrong-handler is the same finding
the baseline parser classified as wrong-handler last time, because the
parser IS the same code.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.parse


# ---------------------------------------------------------------------------
# Warning-message parsing
# ---------------------------------------------------------------------------

# Each warning.message starts with a severity-bracketed header line like
# "[GENERIC] [HIGH] Wrong handler runs for ...". The rest of the message
# carries the location list and the prose explanation.
SEV_RE = re.compile(r"^\[[^\]]+\]\s*\[(HIGH|MEDIUM)\]\s*(.+)$", re.MULTILINE)

# Two LOC patterns: the canonical "/workspace/<path>.py:line:col" used in
# message bodies, AND the duplicate-include variant where the path is
# embedded inside single quotes: "@'/workspace/<path>.py':line:col".
# The "/workspace/" prefix is optional: messages may carry absolute paths
# (real CI bind-mount) OR repo-relative paths (when invoked with
# --project-dir .). Either way the captured path is what we want to
# render — repo-relative.
LOC_RE = re.compile(r"(?:/workspace/)?([\S][^\s:'\"]*\.py):(\d+):(\d+)")
LOC_QUOTED = re.compile(r"'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")

# For duplicate-include findings the message body lists every include
# site with a (runs)/(dead) tag, e.g.
#   "Include sites:
#       (runs)  'app/main.py':36:49
#       (dead)  'app/main.py':37:49"
# The (dead) site is the redundant include the developer should delete,
# so it is the right annotation anchor — without this override the parser
# would otherwise grab the router-allocation site baked into the title
# (heap[s]:pp@'...':14:25), pointing at the APIRouter() call rather
# than the duplicate include_router(...) line.
DEAD_INC_RE = re.compile(r"\(dead\)\s+'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")
ANY_INC_RE = re.compile(r"\((?:runs|dead)\)\s+'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")

FAMILY_KEYS = [
    ("wrong handler",            "wrong-handler"),
    ("duplicate include",        "duplicate-include"),
    ("handler is dead code",     "dead-handler"),
    ("dead handler",             "dead-handler"),
    ("duplicate registration",   "duplicate-registration"),
    ("conditional registration", "conditional-registration"),
]

# Strip the LiSA-internal allocation-site identifier that appears in
# duplicate-include titles (e.g.
#   "router heap[s]:pp@'/workspace/foo.py':19:0 is included 2 times")
# so the rendered title reads as developer-facing prose.
INTERNAL_ID_RE = re.compile(r"\s*heap\[s\]:pp@'[^']+':\d+:\d+")

ALL_FAMILIES = {
    "duplicate-include", "wrong-handler", "dead-handler",
    "duplicate-registration", "conditional-registration", "routing",
}


def family_of(title: str) -> str:
    t = title.lower()
    for needle, label in FAMILY_KEYS:
        if needle in t:
            return label
    return "routing"


def parse_families(families_arg: str) -> set[str] | None:
    """Empty / 'all' / '*' / missing -> None (no filter). Otherwise the
    intersection with ALL_FAMILIES."""
    fams = families_arg.strip().lower()
    if fams in ("", "all", "*"):
        return None
    enabled = {f.strip() for f in fams.split(",") if f.strip()}
    unknown = enabled - ALL_FAMILIES
    if unknown:
        print(
            f"::warning::Unknown family/families in input, ignored: "
            f"{','.join(sorted(unknown))}",
            file=sys.stderr,
        )
    enabled &= ALL_FAMILIES
    if not enabled:
        print(
            "::warning::FAMILIES input resolved to an empty set; "
            "reporting all families instead.",
            file=sys.stderr,
        )
        return None
    return enabled


def parse_warnings(report_path: str, families: set[str] | None) -> list[tuple[str, str, str, str, str, str]]:
    """Return a list of (sev, fam, fpath, fline, title, body) tuples."""
    report = json.load(open(report_path))
    warnings = report.get("warnings") or []
    rows: list[tuple[str, str, str, str, str, str]] = []
    for w in warnings:
        msg = w.get("message", "")
        m = SEV_RE.search(msg)
        if not m:
            continue
        sev, title = m.group(1), m.group(2).strip()
        fam = family_of(title)
        # Apply the families filter as early as possible so downstream
        # counts, annotations, comment, and the gate all see the same
        # filtered view.
        if families is not None and fam not in families:
            continue
        title = INTERNAL_ID_RE.sub("", title).strip()
        # Family-specific anchor: for duplicate-include the right line is
        # the (dead) include site in the body; for everything else the
        # first :line: reference in the message is correct.
        loc = None
        if fam == "duplicate-include":
            loc = DEAD_INC_RE.search(msg) or ANY_INC_RE.search(msg)
        if loc is None:
            loc = LOC_RE.search(msg) or LOC_QUOTED.search(msg)
        # "-" sentinel for "unresolved" so bash read with IFS=$'\t' does
        # not collapse the empty field.
        fpath = loc.group(1) if loc else "-"
        fline = loc.group(2) if loc else "0"
        # Strip the "[GENERIC] [HIGH] " prefix off the raw message so the
        # SARIF text body reads cleanly (level is encoded structurally
        # already), and scrub the analyzer-internal heap[s] identifier.
        body = re.sub(r"^\[[^\]]+\]\s*\[(?:HIGH|MEDIUM)\]\s*", "", msg, count=1)
        body = INTERNAL_ID_RE.sub("", body)
        rows.append((sev, fam, fpath, fline, title, body))
    return rows


# ---------------------------------------------------------------------------
# New-finding classification (used by entrypoint.sh's sticky comment +
# job-summary "NEW" badge column, and by SARIF baselineState="new").
# ---------------------------------------------------------------------------

def _identity(sev: str, fam: str, fpath: str, title: str) -> str:
    """Stable identity for a finding across runs / line drift.

    Deliberately excludes the LINE NUMBER: unrelated edits above the
    finding shift its anchor line, but the finding itself is the same.
    Including line would mark every such shift as "new", drowning the
    actual signal.
    """
    return hashlib.sha256(f"{sev}|{fam}|{fpath}|{title}".encode("utf-8")).hexdigest()


def load_baseline_identities(baseline_tsv: str | None) -> set[str]:
    """Read a baseline findings.tsv (5- or 6-col) into a set of identity
    hashes. Returns an empty set when no path / empty file (treated as
    "first analysis, every finding is new" only if --baseline-findings
    was explicitly provided; otherwise the NEW column is suppressed
    entirely — see write_tsv)."""
    if not baseline_tsv:
        return set()
    try:
        ids: set[str] = set()
        with open(baseline_tsv, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                # Accept both 5-col (legacy / no NEW) and 6-col (new
                # format) baseline files. The NEW column is purely a
                # downstream rendering hint and isn't part of identity.
                if len(parts) == 6:
                    _, sev, fam, fpath, _line, title = parts
                elif len(parts) == 5:
                    sev, fam, fpath, _line, title = parts
                else:
                    continue
                ids.add(_identity(sev, fam, fpath, title))
        return ids
    except FileNotFoundError:
        return set()


def write_tsv(rows: list[tuple[str, str, str, str, str, str]], tsv_path: str,
              baseline_ids: set[str], emit_new_column: bool) -> int:
    """Write the 6-col findings TSV. Returns the number of NEW rows."""
    new_count = 0
    with open(tsv_path, "w") as fh:
        for sev, fam, fpath, fline, title, _body in rows:
            is_new = ""
            if emit_new_column:
                ident = _identity(sev, fam, fpath, title)
                if ident not in baseline_ids:
                    is_new = "NEW"
                    new_count += 1
            fh.write("\t".join((is_new, sev, fam, fpath, fline, title)) + "\n")
    return new_count


# ---------------------------------------------------------------------------
# SARIF 2.1.0 emission
# ---------------------------------------------------------------------------

# Rule catalogue: one entry per defect family. defaultConfiguration.level
# matches the severity assigned by the checker (HIGH→error, MEDIUM→warning);
# per-result `level` still wins, so a hypothetical HIGH dead-handler would
# render as error in the Security tab even though dead-handler's default
# is warning.
RULES = [
    {
        "id": "duplicate-include",
        "name": "DuplicateInclude",
        "shortDescription": {"text": "Router included more than once at the same prefix."},
        "fullDescription": {"text": (
            "The same APIRouter is mounted via include_router(...) more than once at the "
            "same prefix. Under FastAPI's first-match dispatch the later mount is dead: "
            "its routes are appended to the table but never reached, and any extra "
            "arguments it passes (dependencies, tags, ...) are silently dropped."
        )},
        "defaultConfiguration": {"level": "error"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
    {
        "id": "wrong-handler",
        "name": "WrongHandler",
        "shortDescription": {"text": "Route shadowed by an earlier overlapping registration."},
        "fullDescription": {"text": (
            "A concrete route is shadowed by an earlier wildcard or overlapping pattern on "
            "the same router. Requests to the shadowed path are matched first against the "
            "earlier registration; the intended handler never executes."
        )},
        "defaultConfiguration": {"level": "error"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
    {
        "id": "dead-handler",
        "name": "DeadHandler",
        "shortDescription": {"text": "Shadowed handler is otherwise unreferenced — pure dead code."},
        "fullDescription": {"text": (
            "Wrong-handler case where the shadowed handler has no other call sites or "
            "references in the project: the function definition is dead and can be removed "
            "(or the shadow fixed) without behavioural impact."
        )},
        "defaultConfiguration": {"level": "warning"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
    {
        "id": "duplicate-registration",
        "name": "DuplicateRegistration",
        "shortDescription": {"text": "Same (method, path) registered in two different files."},
        "fullDescription": {"text": (
            "The same (HTTP method, path) pair is registered from more than one source "
            "location. Only the first registration in dispatch order wins; the rest are "
            "redundant and a likely sign of a refactor that left a stale registration."
        )},
        "defaultConfiguration": {"level": "warning"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
    {
        "id": "conditional-registration",
        "name": "ConditionalRegistration",
        "shortDescription": {"text": "Same path registered on incomparable if/else branches."},
        "fullDescription": {"text": (
            "The same path is registered on branches that the analyzer cannot order: at "
            "runtime exactly one wins depending on configuration, making the live route "
            "table depend on environment rather than source. Restructure so only one "
            "registration is reachable, or move each branch to a distinct path."
        )},
        "defaultConfiguration": {"level": "warning"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
    {
        "id": "routing",
        "name": "RoutingDefect",
        "shortDescription": {"text": "Routing defect that does not match any specific family."},
        "fullDescription": {"text": "Fallback rule for findings the parser could not classify into a specific family."},
        "defaultConfiguration": {"level": "warning"},
        "helpUri": "https://github.com/giacomozanatta/fastapi-routing-check#defect-families-detected",
    },
]


def sarif_level(sev: str) -> str:
    # SARIF levels: none | note | warning | error. The action only ever
    # surfaces HIGH/MEDIUM, so the mapping is total.
    return "error" if sev.upper() == "HIGH" else "warning"


# Sections whose contents are pre-wrapped prose, not structured location
# data — these get reflowed into one paragraph. Everything else (e.g.
# "Include sites:", "Dead endpoint:", "Registration sites:") is kept
# verbatim inside a fenced code block so the analyzer's intentional
# layout (file:line locations, (runs)/(dead) tags) survives.
_PROSE_HEADERS = {"what happens at runtime", "fix"}
_SECTION_RE = re.compile(r"^(\s*)(\S.*?):\s*$")


def body_to_markdown(body: str) -> str:
    # LiSA's message bodies are pre-wrapped at ~70 columns for terminal
    # display: hard newlines inside paragraphs that GHAS's HTML renderer
    # respects literally, breaking prose into a ragged column. Rebuild
    # the body as markdown so prose reflows into the alert-detail width
    # while structured sections keep their fixed layout.
    lines = body.rstrip().splitlines()
    out, i, n = [], 0, len(lines)
    # First non-blank line is the title-restated summary; emit as-is.
    while i < n and not lines[i].strip():
        i += 1
    if i < n:
        out.append(lines[i].strip())
        i += 1
    while i < n:
        # Skip blank separators between sections.
        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break
        header_match = _SECTION_RE.match(lines[i])
        if not header_match:
            # Loose paragraph not preceded by a "Header:" line — reflow
            # by collecting until the next blank line.
            para = []
            while i < n and lines[i].strip():
                para.append(lines[i].strip())
                i += 1
            out.append("")
            out.append(" ".join(para))
            continue
        header = header_match.group(2).strip()
        i += 1
        # Collect the indented content lines for this section.
        content = []
        while i < n and lines[i].strip():
            content.append(lines[i])
            i += 1
        out.append("")
        out.append(f"**{header}**")
        out.append("")
        if header.lower() in _PROSE_HEADERS:
            out.append(" ".join(c.strip() for c in content))
        else:
            # Strip the minimum common indent so the code block starts at
            # column 0 but preserves relative indentation (e.g. the
            # "    GET /path\n       declared at ...:Line:Col" layout).
            non_empty = [c for c in content if c.strip()]
            min_indent = min((len(c) - len(c.lstrip()) for c in non_empty), default=0)
            out.append("```")
            for c in content:
                out.append(c[min_indent:] if len(c) >= min_indent else c)
            out.append("```")
    return "\n".join(out).strip() + "\n"


def sarif_result(sev: str, fam: str, fpath: str, fline: str, title: str, body: str,
                 is_new: bool, emit_baseline_state: bool) -> dict:
    # partialFingerprints lets GitHub Code Scanning dedupe the same defect
    # across re-runs even when line numbers drift. We intentionally
    # exclude the line number from the input so the fingerprint is stable
    # across reformats.
    fp = hashlib.sha256(f"{fam}|{fpath}|{title}".encode("utf-8")).hexdigest()
    result: dict = {
        "ruleId": fam,
        "level": sarif_level(sev),
        # GHAS renders message.markdown when present, falls back to .text.
        # We keep .text as the raw analyzer body for non-GitHub SARIF
        # consumers (VS Code SARIF Viewer, sarifweb.azurewebsites.net,
        # etc.) and provide a reflowed markdown variant for the Code
        # Scanning alert detail view.
        "message": {
            "text": body.strip(),
            "markdown": body_to_markdown(body),
        },
        "partialFingerprints": {"primaryLocationLineHash": fp},
        "properties": {"severity": sev.lower()},
    }
    if emit_baseline_state:
        # SARIF baselineState: "new" | "unchanged" | "updated" | "absent".
        # We only know new-vs-existing (the line-stable identity diff);
        # "unchanged" is correct for everything else under that scheme.
        # GitHub Code Scanning surfaces "new" as a distinct PR-check
        # signal, which is the whole point of this column.
        result["baselineState"] = "new" if is_new else "unchanged"
    if fpath != "-" and fpath:
        # urllib.parse.quote keeps "/" literal so the SARIF URI matches
        # the on-disk repo path GitHub expects; only exotic chars get
        # %-encoded.
        result["locations"] = [{
            "physicalLocation": {
                "artifactLocation": {"uri": urllib.parse.quote(fpath, safe="/")},
                "region": {"startLine": int(fline) if fline.isdigit() and int(fline) > 0 else 1},
            }
        }]
    return result


def write_sarif(rows: list[tuple[str, str, str, str, str, str]], sarif_path: str,
                tool_version: str, baseline_ids: set[str], emit_baseline_state: bool) -> None:
    sarif = {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {
                "driver": {
                    # Display name shown in the GHAS Code Scanning UI
                    # ("GitHub Advanced Security / LiSA FastAPI Routing
                    # Checker") and in each alert's "Tool" column.
                    "name": "LiSA FastAPI Routing Checker",
                    "informationUri": "https://github.com/giacomozanatta/fastapi-routing-check",
                    "version": tool_version,
                    "rules": RULES,
                },
            },
            # automationDetails.id becomes the Code Scanning "category"
            # if the upload-sarif step doesn't set one explicitly.
            "automationDetails": {"id": "fastapi-routing-check"},
            "results": [
                sarif_result(
                    sev, fam, fpath, fline, title, body,
                    is_new=_identity(sev, fam, fpath, title) not in baseline_ids,
                    emit_baseline_state=emit_baseline_state,
                )
                for sev, fam, fpath, fline, title, body in rows
            ],
        }],
    }
    with open(sarif_path, "w") as f:
        json.dump(sarif, f, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Parse lisa-network report.json into findings.tsv (and optionally results.sarif).")
    ap.add_argument("report", help="path to lisa-network's report.json")
    ap.add_argument("findings_tsv", help="output path for the 6-col findings.tsv")
    ap.add_argument("--sarif", help="output path for the SARIF 2.1.0 file (omit to skip)")
    ap.add_argument("--families", default="all", help="comma-separated family filter; 'all' / '*' / '' to include every family")
    ap.add_argument("--version", default="dev", help="tool.driver.version for the SARIF emission")
    ap.add_argument(
        "--baseline-findings",
        help="path to a previously-produced findings.tsv (typically the PR merge-base's). When given, the head TSV's NEW column is populated for findings whose identity (sev|family|file|title) is absent from the baseline.",
    )
    args = ap.parse_args(argv[1:])

    families = parse_families(args.families)
    rows = parse_warnings(args.report, families)
    baseline_ids = load_baseline_identities(args.baseline_findings)
    emit_new_column = args.baseline_findings is not None

    new_count = write_tsv(rows, args.findings_tsv, baseline_ids, emit_new_column)
    print(f"parsed {len(rows)} findings ({new_count} NEW) -> {args.findings_tsv}", file=sys.stderr)

    if args.sarif:
        write_sarif(rows, args.sarif, args.version, baseline_ids, emit_baseline_state=emit_new_column)
        print(f"emitted SARIF -> {args.sarif}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
