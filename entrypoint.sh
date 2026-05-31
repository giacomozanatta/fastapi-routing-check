#!/usr/bin/env bash
# fastapi-routing-check action entrypoint.
#
# Required env (set by action.yml):
#   MAIN_FILE              entrypoint path, relative to repo root
#   PROJECT_DIR            project root passed to the analyzer
#   OUTPUT_DIR             where final-network.* and report.json land
#   FAIL_ON_FINDING        "true" | "false"
#   SEVERITY_THRESHOLD     "high" | "medium"
#   JVM_HEAP               max heap (e.g. 4g)
#   COMMENT_ON_PR          "true" | "false" — post a sticky PR comment
#   ANNOTATIONS            "true" | "false" — emit ::warning:: annotations
#   ACTION_PATH            absolute path to this action's checkout
#                          (provided by GitHub as ${{ github.action_path }});
#                          ${ACTION_PATH}/dist/lisa-network/ is the bundled
#                          analyzer distribution committed to the action repo
#   GH_TOKEN               used by `gh` to post/update the PR comment

set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
mkdir -p "$WORKSPACE/$OUTPUT_DIR"

ANALYZER="${ACTION_PATH}/dist/lisa-network/bin/lisa-network"
if [[ ! -x "$ANALYZER" ]]; then
  echo "::error::Bundled analyzer not found or not executable at $ANALYZER. The action repo may be missing dist/lisa-network/."
  exit 3
fi

# ---------------------------------------------------------------------------
# 1. Run the analyzer
#
# The analyzer resolves --main-file relative to the current working
# directory, so we cd into the user's repo root first. JAVA_TOOL_OPTIONS
# forwards the heap setting without touching the launcher script.
# ---------------------------------------------------------------------------
(
  cd "$WORKSPACE"
  JAVA_TOOL_OPTIONS="-Xmx${JVM_HEAP}" \
  "$ANALYZER" \
    --main-file   "$MAIN_FILE" \
    --project-dir "$PROJECT_DIR" \
    --output-dir  "$OUTPUT_DIR" \
    --no-cfg-dump
)

REPORT="$WORKSPACE/$OUTPUT_DIR/report.json"
FINAL_TXT="$WORKSPACE/$OUTPUT_DIR/final-network.txt"

if [[ ! -f "$REPORT" ]]; then
  echo "::error::report.json not produced at $REPORT — analyzer likely failed before checker stage."
  exit 2
fi

# ---------------------------------------------------------------------------
# 2. Parse warnings into a structured table + a SARIF 2.1.0 file
#
# Each warning is a single .message string; severity is bracketed in the
# first line ("[GENERIC] [HIGH] ..."), and file:line references are
# embedded inline. We extract:
#   - severity   ← [HIGH] / [MEDIUM] in the header
#   - title      ← rest of the header line
#   - family     ← derived from title keywords
#   - file:line  ← first absolute path:line:col after "/workspace/", made
#                  repo-relative by stripping the bind-mount prefix
# The result lands in $OUTPUT_DIR/findings.tsv as
#   severity \t family \t file \t line \t title
# which both the annotation emitter and the PR-comment poster consume,
# AND in $OUTPUT_DIR/results.sarif (SARIF 2.1.0), which any consuming
# workflow can hand to github/codeql-action/upload-sarif to render
# findings natively in the PR's Code Scanning tab / Security tab.
# The SARIF is emitted unconditionally — an empty results array tells
# GitHub Code Scanning to clear stale findings on the branch.
# ---------------------------------------------------------------------------
FINDINGS_TSV="$WORKSPACE/$OUTPUT_DIR/findings.tsv"
SARIF="$WORKSPACE/$OUTPUT_DIR/results.sarif"
# GITHUB_ACTION_REF is set by the runner to the ref/tag the action was
# resolved at (e.g. "v0.1.0"); empty when invoked via `uses: ./` in the
# self-test workflow or run locally, so fall back to "dev".
ACTION_VERSION="${GITHUB_ACTION_REF:-dev}"

python3 - "$REPORT" "$FINDINGS_TSV" "$SARIF" "${FAMILIES:-all}" "$ACTION_VERSION" <<'PY'
import hashlib, json, os, re, sys, urllib.parse
report_path, tsv_path, sarif_path, families_arg, tool_version = sys.argv[1:6]
report = json.load(open(report_path))
warnings = report.get("warnings") or []

# Parse the FAMILIES input. Empty / "all" / "*" / missing => no filter.
# Otherwise drop findings whose family is not in the enabled set.
ALL_FAMILIES = {"duplicate-include", "wrong-handler", "dead-handler",
                "duplicate-registration", "conditional-registration", "routing"}
fams = families_arg.strip().lower()
if fams in ("", "all", "*"):
    enabled = None  # no filter
else:
    enabled = {f.strip() for f in fams.split(",") if f.strip()}
    unknown = enabled - ALL_FAMILIES
    if unknown:
        print(f"::warning::Unknown family/families in input, ignored: {','.join(sorted(unknown))}",
              file=sys.stderr)
    enabled &= ALL_FAMILIES
    if not enabled:
        print("::warning::FAMILIES input resolved to an empty set; reporting all families instead.",
              file=sys.stderr)
        enabled = None

SEV_RE   = re.compile(r"^\[[^\]]+\]\s*\[(HIGH|MEDIUM)\]\s*(.+)$", re.MULTILINE)
# Two LOC patterns: the canonical "/workspace/<path>.py:line:col" used in
# message bodies, AND the duplicate-include variant where the path is
# embedded inside single quotes: "@'/workspace/<path>.py':line:col".
# The "/workspace/" prefix is optional: messages may carry absolute
# paths (real CI bind-mount) OR repo-relative paths (when invoked with
# --project-dir .). Either way the captured path is what we want to
# render — repo-relative.
LOC_RE       = re.compile(r"(?:/workspace/)?([\S][^\s:'\"]*\.py):(\d+):(\d+)")
LOC_QUOTED   = re.compile(r"'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")
# For duplicate-include findings the message body lists every include
# site with a (runs)/(dead) tag, e.g.
#   "Include sites:
#       (runs)  'app/main.py':36:49
#       (dead)  'app/main.py':37:49"
# The (dead) site is the redundant include the developer should delete,
# so it is the right annotation anchor — without this override the
# parser would otherwise grab the router-allocation site baked into
# the title (heap[s]:pp@'...':14:25), pointing at the APIRouter() call
# rather than the duplicate include_router(...) line.
DEAD_INC_RE  = re.compile(r"\(dead\)\s+'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")
ANY_INC_RE   = re.compile(r"\((?:runs|dead)\)\s+'(?:/workspace/)?([^']+\.py)':(\d+):(\d+)")
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

def family_of(title: str) -> str:
    t = title.lower()
    for needle, label in FAMILY_KEYS:
        if needle in t:
            return label
    return "routing"

rows = []
for w in warnings:
    msg = w.get("message", "")
    m = SEV_RE.search(msg)
    if not m:
        continue
    sev, title = m.group(1), m.group(2).strip()
    fam = family_of(title)
    # Apply the families filter as early as possible: drop the finding
    # before its location is even resolved, so downstream counts,
    # annotations, comment, and the gate all see the same filtered view.
    if enabled is not None and fam not in enabled:
        continue
    title = INTERNAL_ID_RE.sub("", title).strip()
    # Family-specific anchor selection: for duplicate-include the
    # right line is the (dead) include site in the body; for everything
    # else the first :line: reference in the message is correct.
    loc = None
    if fam == "duplicate-include":
        loc = DEAD_INC_RE.search(msg) or ANY_INC_RE.search(msg)
    if loc is None:
        loc = LOC_RE.search(msg) or LOC_QUOTED.search(msg)
    # Use "-" as a sentinel for "unresolved" so bash `read` with IFS=$'\t'
    # does not collapse the empty field (tab is whitespace; consecutive
    # whitespace IFS chars are treated as a single delimiter).
    fpath = loc.group(1) if loc else "-"
    fline = loc.group(2) if loc else "0"
    # Strip the "[GENERIC] [HIGH] " prefix off the raw message so the SARIF
    # text body reads cleanly (level is already encoded structurally), and
    # scrub the analyzer-internal heap[s] identifier wherever it appears
    # inside the body for the same reason as in the title.
    body = re.sub(r"^\[[^\]]+\]\s*\[(?:HIGH|MEDIUM)\]\s*", "", msg, count=1)
    body = INTERNAL_ID_RE.sub("", body)
    rows.append((sev, fam, fpath, fline, title, body))

with open(tsv_path, "w") as f:
    for r in rows:
        # TSV remains 5-column; the body is consumed only by SARIF.
        f.write("\t".join(r[:5]) + "\n")

# ---------- SARIF 2.1.0 emission -------------------------------------------
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

def sarif_result(sev, fam, fpath, fline, title, body):
    # partialFingerprints lets GitHub Code Scanning dedupe the same defect
    # across re-runs even when line numbers drift (e.g. unrelated edits
    # above the finding shift its anchor line). The "primaryLocationLineHash"
    # key is the conventional GH name; we intentionally exclude the line
    # number from the input so the fingerprint is stable across reformats.
    fp_input = f"{fam}|{fpath}|{title}".encode("utf-8")
    fp = hashlib.sha256(fp_input).hexdigest()
    result = {
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
    if fpath != "-" and fpath:
        # urllib.parse.quote keeps "/" literal so the SARIF URI matches
        # the on-disk repo path GitHub expects; only exotic chars get %-encoded.
        result["locations"] = [{
            "physicalLocation": {
                "artifactLocation": {"uri": urllib.parse.quote(fpath, safe="/")},
                "region": {"startLine": int(fline) if fline.isdigit() and int(fline) > 0 else 1},
            }
        }]
    return result

sarif = {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "version": "2.1.0",
    "runs": [{
        "tool": {
            "driver": {
                # Display name shown in the GHAS Code Scanning UI
                # ("GitHub Advanced Security / LiSA FastAPI Routing
                # Checker") and in each alert's "Tool" column. Stays
                # human-readable; the stable slug used for Code Scanning
                # category / dedup lives in automationDetails.id below.
                "name": "LiSA FastAPI Routing Checker",
                "informationUri": "https://github.com/giacomozanatta/fastapi-routing-check",
                "version": tool_version,
                "rules": RULES,
            },
        },
        # automationDetails.id becomes the Code Scanning "category" if the
        # upload-sarif step doesn't set one explicitly — keeps this tool's
        # results from overwriting findings from other analyzers on the
        # same ref.
        "automationDetails": {"id": "fastapi-routing-check"},
        "results": [sarif_result(*r) for r in rows],
    }],
}

with open(sarif_path, "w") as f:
    json.dump(sarif, f, indent=2)

print(f"parsed {len(rows)} findings -> {tsv_path}")
print(f"emitted SARIF -> {sarif_path}")
PY

# Counts.
findings_count=$(wc -l < "$FINDINGS_TSV" | tr -d ' ')
high_count=$(awk -F'\t' 'tolower($1)=="high"' "$FINDINGS_TSV" | wc -l | tr -d ' ')
medium_count=$(awk -F'\t' 'tolower($1)=="medium"' "$FINDINGS_TSV" | wc -l | tr -d ' ')

endpoints_count="0"
ENDPOINTS_TSV="$WORKSPACE/$OUTPUT_DIR/endpoints.tsv"
: > "$ENDPOINTS_TSV"
if [[ -f "$FINAL_TXT" ]]; then
  endpoints_count=$(grep -Eo 'COUNT[[:space:]]*[:=][[:space:]]*[0-9]+' "$FINAL_TXT" \
    | head -n1 | grep -Eo '[0-9]+' || echo 0)
  # Parse the per-method endpoint listing out of final-network.txt into
  # a 4-column TSV (METHOD \t PATH \t FILE \t LINE). The parser lives in
  # bin/parse-endpoints.py so the baseline analysis (merge-base, for the
  # endpoint-delta feature) and the head analysis here share a single
  # source of truth on what counts as an endpoint row — any drift between
  # the two would otherwise surface as fake "added"/"removed" rows in the
  # delta.
  python3 "${ACTION_PATH}/bin/parse-endpoints.py" "$FINAL_TXT" "$ENDPOINTS_TSV"
fi

{
  echo "endpoints-count=$endpoints_count"
  echo "findings-count=$findings_count"
  echo "high-severity-count=$high_count"
  echo "report-path=$OUTPUT_DIR/report.json"
  echo "sarif-path=$OUTPUT_DIR/results.sarif"
} >> "$GITHUB_OUTPUT"

# ---------------------------------------------------------------------------
# 2.5. Endpoint delta vs PR merge-base
#
# Always run compute-delta.py — even when no baseline exists (non-PR event
# or fork PR without merge-base resolution), the script handles missing /
# empty input gracefully and emits a zero-totals delta.json. That keeps
# downstream consumers (workflow Summary, sticky PR comment, action
# outputs) seeing a consistent JSON shape.
#
# This logic intentionally lives in entrypoint.sh — running it as a
# trailing composite step in action.yml means the sticky PR comment
# written below (section 5) couldn't embed the delta section.
# ---------------------------------------------------------------------------
BASELINE_TSV="$WORKSPACE/${OUTPUT_DIR}-baseline/endpoints.tsv"
DELTA_JSON="$WORKSPACE/$OUTPUT_DIR/delta.json"
DELTA_MARKDOWN_PLAIN=""        # job-summary surface (unlinked file:line)
DELTA_MARKDOWN_LINKED=""       # sticky-comment surface (file:line → repo blob)
endpoints_added=0
endpoints_removed=0
endpoints_moved=0

# Create an empty baseline file if the action's baseline step decided not
# to run (push event, fork PR, endpoint-delta input set to false). The
# diff script treats empty-vs-populated as "first run, no baseline" and
# emits status=ok with all-zero totals.
[[ -f "$BASELINE_TSV" ]] || { mkdir -p "$(dirname "$BASELINE_TSV")"; : > "$BASELINE_TSV"; }
[[ -f "$ENDPOINTS_TSV" ]] || : > "$ENDPOINTS_TSV"

python3 "${ACTION_PATH}/bin/compute-delta.py" "$BASELINE_TSV" "$ENDPOINTS_TSV" "$DELTA_JSON"

# Pull the totals back out for action outputs + the renderer's gate.
endpoints_added=$(python3 -c "import json; print(json.load(open('$DELTA_JSON'))['totals'].get('added', 0))")
endpoints_removed=$(python3 -c "import json; print(json.load(open('$DELTA_JSON'))['totals'].get('removed', 0))")
endpoints_moved=$(python3 -c "import json; print(json.load(open('$DELTA_JSON'))['totals'].get('moved', 0))")

# Render twice — the renderer's --repo-url/--sha switch toggles whether
# file:line cells become permalinks. Job summary doesn't need links
# (it's already inside the workflow run page); the sticky PR comment
# does (the reader is on the Conversation tab, away from the source).
DELTA_MARKDOWN_PLAIN=$(python3 "${ACTION_PATH}/bin/render-delta.py" "$DELTA_JSON")
if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_SHA:-}" ]]; then
  DELTA_MARKDOWN_LINKED=$(python3 "${ACTION_PATH}/bin/render-delta.py" "$DELTA_JSON" \
    --repo-url "https://github.com/${GITHUB_REPOSITORY}" --sha "$GITHUB_SHA")
else
  DELTA_MARKDOWN_LINKED="$DELTA_MARKDOWN_PLAIN"
fi

{
  echo "endpoints-added=$endpoints_added"
  echo "endpoints-removed=$endpoints_removed"
  echo "endpoints-moved=$endpoints_moved"
  echo "delta-path=$OUTPUT_DIR/delta.json"
} >> "$GITHUB_OUTPUT"

# ---------------------------------------------------------------------------
# 3. Job summary (always — visible at the top of the Actions run page)
# ---------------------------------------------------------------------------
{
  echo "## FastAPI routing check"
  echo
  echo "| Metric | Value |"
  echo "|---|---:|"
  echo "| Endpoints recovered | $endpoints_count |"
  echo "| Findings (total) | $findings_count |"
  echo "| Findings (high) | $high_count |"
  echo "| Findings (medium) | $medium_count |"
  echo
  if (( findings_count > 0 )); then
    echo "| Severity | Family | Where | What |"
    echo "|---|---|---|---|"
    while IFS=$'\t' read -r sev fam fpath fline title; do
      if [[ "$fpath" == "-" || -z "$fpath" ]]; then
        where="(unresolved)"
      else
        where="\`$fpath:$fline\`"
      fi
      echo "| $sev | $fam | $where | $title |"
    done < "$FINDINGS_TSV"
  fi

  # Endpoint delta section — emitted only when the renderer produced
  # output (i.e. at least one added/removed/moved, OR an asymmetric-zero
  # warning). Empty output on no-op PRs keeps the summary tight.
  if [[ -n "$DELTA_MARKDOWN_PLAIN" ]]; then
    echo
    echo "$DELTA_MARKDOWN_PLAIN"
  fi

  # Collapsible endpoint inventory — always emitted when at least one
  # endpoint was recovered, so reviewers can audit the topology the
  # checker reasoned over without downloading final-network.txt.
  if [[ -s "$ENDPOINTS_TSV" ]]; then
    n_ep=$(wc -l < "$ENDPOINTS_TSV" | tr -d ' ')
    echo
    echo "<details>"
    echo "<summary>All endpoints ($n_ep)</summary>"
    echo
    echo "| Method | Path | Source |"
    echo "|---|---|---|"
    while IFS=$'\t' read -r method epath efpath efline; do
      esrc="\`$efpath:$efline\`"
      [[ "$efpath" == "-" || -z "$efpath" ]] && esrc="(unresolved)"
      echo "| $method | \`$epath\` | $esrc |"
    done < "$ENDPOINTS_TSV"
    echo
    echo "</details>"
  fi
} >> "$GITHUB_STEP_SUMMARY"

# ---------------------------------------------------------------------------
# 4. Inline annotations on the Files Changed tab
#
# These are the lightweight, no-permission-needed surface — they DO render
# next to the offending line in the diff view, but GitHub silently truncates
# after 10 per type per run, so they are best-effort.
# ---------------------------------------------------------------------------
if [[ "${ANNOTATIONS:-true}" == "true" && "$findings_count" -gt 0 ]]; then
  while IFS=$'\t' read -r sev fam fpath fline title; do
    [[ "$fpath" == "-" || -z "$fpath" ]] && continue
    sev_lc=$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')
    level="warning"; [[ "$sev_lc" == "high" ]] && level="error"
    # Escape % \n \r for workflow commands.
    safe="$(printf '%s' "[$sev $fam] $title" | sed -e 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
    echo "::${level} file=${fpath},line=${fline}::${safe}"
  done < "$FINDINGS_TSV"
fi

# ---------------------------------------------------------------------------
# 5. Sticky PR comment — the real "comment on the PR that points at the
#    file" surface. Re-runs edit the existing comment in place via a
#    sentinel HTML marker (<!-- fastapi-routing-check -->) so the PR
#    timeline never accumulates duplicates.
# ---------------------------------------------------------------------------
if [[ "${COMMENT_ON_PR:-true}" == "true" && "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "::warning::gh CLI not available in this runner; skipping PR comment."
  else
    # Pull the PR number from the event payload — robust across PR
    # event subtypes (opened/synchronize/reopened) and unaffected by
    # GITHUB_REF's "refs/pull/N/merge" shape that an earlier version of
    # this script tried (and failed) to parse.
    PR_NUMBER=""
    if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
      PR_NUMBER=$(jq -r '.pull_request.number // .number // empty' "$GITHUB_EVENT_PATH")
    fi
    if [[ -z "$PR_NUMBER" || ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "::warning::Could not resolve PR number from event payload; skipping PR comment."
      PR_NUMBER=""
    fi
    REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
    SHA="${GITHUB_SHA}"  # commit being analysed — file links pin to it
    MARKER="<!-- fastapi-routing-check -->"

    BODY_FILE="$WORKSPACE/$OUTPUT_DIR/pr-comment.md"
    {
      echo "$MARKER"
      echo "### Lisa &mdash; FastAPI routing check"
      echo "<sub>Static analysis by <a href=\"https://github.com/lisa-analyzer/lisa\">LiSA</a> via <a href=\"https://github.com/giacomozanatta/fastapi-routing-check\">fastapi-routing-check</a></sub>"
      echo
      if (( findings_count == 0 )); then
        echo ":white_check_mark: No routing defects detected across **$endpoints_count** recovered endpoints."
      else
        echo "**Found $findings_count finding(s)** &mdash; $high_count high, $medium_count medium &mdash; across **$endpoints_count** recovered endpoints."
        echo
        echo "| Severity | Family | Where | What |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r sev fam fpath fline title; do
          if [[ "$fpath" == "-" || -z "$fpath" ]]; then
            where="(unresolved)"
          else
            where="[\`$fpath:$fline\`]($REPO_URL/blob/$SHA/$fpath#L$fline)"
          fi
          # Pipe-escape the title so it doesn't break the markdown table.
          esc_title=$(printf '%s' "$title" | sed 's/|/\\|/g')
          sev_lc=$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')
          icon=":small_red_triangle:"; [[ "$sev_lc" == "medium" ]] && icon=":small_orange_diamond:"
          echo "| $icon $sev | $fam | $where | $esc_title |"
        done < "$FINDINGS_TSV"
      fi

      # Endpoint delta — emit only when the renderer produced output,
      # so no-op PRs don't gain an "Endpoint delta vs base" heading
      # followed by nothing. Linked variant used here (PR readers are
      # on the Conversation tab, source links help).
      if [[ -n "$DELTA_MARKDOWN_LINKED" ]]; then
        echo
        echo "$DELTA_MARKDOWN_LINKED"
      fi

      # Collapsible endpoint inventory — emitted in both the
      # "no findings" and "findings" branches so reviewers can audit
      # the topology the checker reasoned over.
      if [[ -s "$ENDPOINTS_TSV" ]]; then
        n_ep=$(wc -l < "$ENDPOINTS_TSV" | tr -d ' ')
        echo
        echo "<details>"
        echo "<summary>All endpoints ($n_ep)</summary>"
        echo
        echo "| Method | Path | Source |"
        echo "|---|---|---|"
        while IFS=$'\t' read -r method epath efpath efline; do
          if [[ "$efpath" == "-" || -z "$efpath" ]]; then
            esrc="(unresolved)"
          else
            esrc="[\`$efpath:$efline\`]($REPO_URL/blob/$SHA/$efpath#L$efline)"
          fi
          esc_path=$(printf '%s' "$epath" | sed 's/|/\\|/g')
          echo "| \`$method\` | \`$esc_path\` | $esrc |"
        done < "$ENDPOINTS_TSV"
        echo
        echo "</details>"
      fi
      echo
      echo "_<sub>Lisa &middot; full \`report.json\`, \`final-network.pdf\`, and \`final-network.txt\` available as \`lisa-network-report\` on run <a href=\"$REPO_URL/actions/runs/${GITHUB_RUN_ID}\">#${GITHUB_RUN_ID}</a> &middot; commit <code>${SHA:0:7}</code></sub>_"
    } > "$BODY_FILE"

    # Find an existing sticky comment (by sentinel) and edit it; otherwise create one.
    existing_id=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
      --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" \
      | head -n1 || true)

    if [[ -n "$existing_id" ]]; then
      gh api --method PATCH \
        "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
        -f body="$(cat "$BODY_FILE")" >/dev/null
      echo "Updated sticky PR comment (id=$existing_id)."
    else
      gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \
        --body-file "$BODY_FILE" >/dev/null
      echo "Posted sticky PR comment."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. Gate
# ---------------------------------------------------------------------------
if [[ "$FAIL_ON_FINDING" != "true" ]]; then
  echo "fail-on-finding=false; not gating job."
  exit 0
fi

case "$SEVERITY_THRESHOLD" in
  high)
    if (( high_count > 0 )); then
      echo "::error::$high_count high-severity routing finding(s) — failing job."
      exit 1
    fi
    ;;
  medium|*)
    if (( findings_count > 0 )); then
      echo "::error::$findings_count routing finding(s) at severity >= medium — failing job."
      exit 1
    fi
    ;;
esac

echo "No findings at or above severity '$SEVERITY_THRESHOLD'."
