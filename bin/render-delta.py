#!/usr/bin/env python3
"""Render a delta.json (produced by compute-delta.py) into a markdown
section suitable for the sticky PR comment, the workflow job summary,
or any other surface that consumes GitHub-flavoured markdown.

Two call modes share one renderer so the comment and the summary cannot
drift apart:

  - With --repo-url and --sha: the "Where" cells become clickable
    permalinks (PR comment style — points at the analysed commit).
  - Without them: plain `file:line` backticks (job-summary style — the
    summary already renders inside the workflow page so external links
    would be redundant noise).

Outputs nothing (exit 0, empty stdout) when the delta has no
add/remove/move rows AND status == "ok". Keeps no-op PRs visually
quiet — adding a section that says "no changes" every time would
just train reviewers to skim past it.

Usage:
  render-delta.py <delta.json>
                  [--repo-url <https://github.com/owner/repo>]
                  [--sha <commit-sha>]
                  [--max-rows <N>]   (default 20 per category)
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def _where_head(site: dict[str, str], repo_url: str | None, sha: str | None) -> str:
    """Render a site as `file:line`, linked if (repo_url, sha) are provided."""
    f, l = site["file"], site["line"]
    label = f"`{f}:{l}`"
    if repo_url and sha:
        return f"[{label}]({repo_url}/blob/{sha}/{f}#L{l})"
    return label


def _where_baseline(site: dict[str, str]) -> str:
    """Render a baseline-side site. Never linked — the merge-base SHA isn't
    in the comment context, and linking to head/sha would 404 for files
    the PR deleted.
    """
    return f"`{site['file']}:{site['line']}`"


def _site_list(sites: list[dict[str, str]], repo_url: str | None, sha: str | None) -> str:
    """Join multiple sites with ` · `. Used when moved.added_sites or
    moved.removed_sites has more than one entry (duplicate-include
    fixed / introduced scenarios).
    """
    return " · ".join(_where_head(s, repo_url, sha) for s in sites)


def _esc(s: str) -> str:
    """Escape pipe + backtick for markdown-table cells. Path strings can
    legitimately contain neither in practice, but a defensive escape
    keeps the table from breaking on a pathological fixture.
    """
    return s.replace("|", "\\|")


def render(delta: dict[str, Any], repo_url: str | None, sha: str | None, max_rows: int) -> str:
    status = delta.get("status", "ok")
    totals = delta.get("totals", {})
    added = delta.get("added", [])
    removed = delta.get("removed", [])
    moved = delta.get("moved", [])

    if status == "suppressed-asymmetric-zero":
        # One analysis side returned zero endpoints, the other returned
        # many. Rendering the diff would be a wall of phantom rows; the
        # honest message is "we can't tell". Surface enough detail that
        # the reviewer can act on it (look at the artefact, re-run).
        return (
            "### Endpoint delta vs base\n\n"
            ":warning: **Delta unavailable** — one side of the analysis "
            f"returned zero endpoints (baseline={totals.get('baseline', 0)}, "
            f"head={totals.get('head', 0)}). The analyser likely crashed on one "
            "side; check the run log and the `lisa-network-report` artefact.\n"
        )

    if not (added or removed or moved):
        # Truly no change — emit nothing. The summary line at the top of
        # the comment already reports endpoint count, so the reader has
        # the "nothing changed in the API surface" information without a
        # dedicated section.
        return ""

    parts: list[str] = []
    parts.append("### Endpoint delta vs base")
    parts.append("")

    # Headline summary line: bold the non-zero categories so reviewers
    # immediately see which axis moved.
    def _bold_if(n: int, label: str) -> str:
        return f"**{n} {label}**" if n else f"{n} {label}"

    parts.append(
        " · ".join([
            _bold_if(totals.get("added", 0), "added"),
            _bold_if(totals.get("removed", 0), "removed"),
            _bold_if(totals.get("moved", 0), "moved"),
            f"{totals.get('unchanged', 0)} unchanged",
        ])
    )
    parts.append("")
    parts.append("| Δ | Method | Path | Where |")
    parts.append("|---|---|---|---|")

    def _truncated_note(n: int, shown: int, kind: str) -> str | None:
        if n <= shown:
            return None
        return f"| | | | _… {n - shown} more {kind} omitted; full list in `delta.json` artefact_ |"

    for row in added[:max_rows]:
        parts.append(
            f"| <kbd>+</kbd> | `{row['method']}` | `{_esc(row['path'])}` | "
            f"{_where_head(row, repo_url, sha)} |"
        )
    note = _truncated_note(len(added), max_rows, "added")
    if note:
        parts.append(note)

    for row in removed[:max_rows]:
        # Site is the baseline location — render unlinked because that
        # file/line may not exist on HEAD (deleted/renamed).
        baseline_site = {"file": row["file"], "line": row["line"]}
        parts.append(
            f"| <kbd>−</kbd> | `{row['method']}` | `{_esc(row['path'])}` | "
            f"(was {_where_baseline(baseline_site)}) |"
        )
    note = _truncated_note(len(removed), max_rows, "removed")
    if note:
        parts.append(note)

    for row in moved[:max_rows]:
        to_sites = row.get("to", [])
        from_sites = row.get("from", [])
        # Compact rendering for the common 1-to-1 case; expand to a site
        # list for duplicate-include fixed/introduced scenarios.
        if len(to_sites) == 1 and len(from_sites) == 1:
            where = (
                f"{_where_head(to_sites[0], repo_url, sha)} "
                f"(was {_where_baseline(from_sites[0])})"
            )
        else:
            to_str = _site_list(to_sites, repo_url, sha) if to_sites else "_(none)_"
            from_str = " · ".join(_where_baseline(s) for s in from_sites) if from_sites else "_(none)_"
            where = f"now: {to_str} · was: {from_str}"
        parts.append(
            f"| <kbd>~</kbd> | `{row['method']}` | `{_esc(row['path'])}` | {where} |"
        )
    note = _truncated_note(len(moved), max_rows, "moved")
    if note:
        parts.append(note)

    parts.append("")
    return "\n".join(parts) + "\n"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Render delta.json as markdown.")
    ap.add_argument("delta_json", help="path to delta.json produced by compute-delta.py")
    ap.add_argument("--repo-url", help="https://github.com/<owner>/<repo>; enables clickable file:line links")
    ap.add_argument("--sha", help="commit SHA for the head side; required with --repo-url to anchor links")
    ap.add_argument("--max-rows", type=int, default=20, help="cap rows per category (default 20)")
    args = ap.parse_args(argv[1:])
    if bool(args.repo_url) != bool(args.sha):
        print("error: --repo-url and --sha must be provided together", file=sys.stderr)
        return 2
    with open(args.delta_json) as fh:
        delta = json.load(fh)
    sys.stdout.write(render(delta, args.repo_url, args.sha, args.max_rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
