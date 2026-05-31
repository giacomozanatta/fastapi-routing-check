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
# 2. Parse warnings into a structured table
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
# which both the annotation emitter and the PR-comment poster consume.
# ---------------------------------------------------------------------------
FINDINGS_TSV="$WORKSPACE/$OUTPUT_DIR/findings.tsv"

python3 - "$REPORT" "$FINDINGS_TSV" "${FAMILIES:-all}" <<'PY'
import json, os, re, sys
report_path, tsv_path, families_arg = sys.argv[1], sys.argv[2], sys.argv[3]
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
    rows.append((sev, fam, fpath, fline, title))

with open(tsv_path, "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")

print(f"parsed {len(rows)} findings -> {tsv_path}")
PY

# Counts.
findings_count=$(wc -l < "$FINDINGS_TSV" | tr -d ' ')
high_count=$(awk -F'\t' 'tolower($1)=="high"' "$FINDINGS_TSV" | wc -l | tr -d ' ')
medium_count=$(awk -F'\t' 'tolower($1)=="medium"' "$FINDINGS_TSV" | wc -l | tr -d ' ')

endpoints_count="0"
if [[ -f "$FINAL_TXT" ]]; then
  endpoints_count=$(grep -Eo 'COUNT[[:space:]]*[:=][[:space:]]*[0-9]+' "$FINAL_TXT" \
    | head -n1 | grep -Eo '[0-9]+' || echo 0)
fi

{
  echo "endpoints-count=$endpoints_count"
  echo "findings-count=$findings_count"
  echo "high-severity-count=$high_count"
  echo "report-path=$OUTPUT_DIR/report.json"
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
        echo
        echo "<details><summary>Full report (collapsed)</summary>"
        echo
        echo "Download \`lisa-network-report\` from this run's artefacts for the complete \`report.json\`, \`final-network.html\`, and \`final-network.txt\`."
        echo
        echo "</details>"
      fi
      echo
      echo "_<sub>Lisa &middot; run <a href=\"$REPO_URL/actions/runs/${GITHUB_RUN_ID}\">#${GITHUB_RUN_ID}</a> &middot; commit <code>${SHA:0:7}</code></sub>_"
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
