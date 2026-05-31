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

# Findings parsing + SARIF emission lives in bin/parse-warnings.py so the
# baseline analysis (bin/run-baseline-analysis.sh) can produce its own
# baseline findings.tsv from the same parser — no drift risk on the
# new-finding classification. --baseline-findings makes the head TSV's
# 1st column carry "NEW" for findings whose identity (sev|family|file|
# title, line-stable) is absent from the baseline, and adds
# baselineState="new"/"unchanged" to each SARIF result.
BASELINE_FINDINGS_TSV="$WORKSPACE/${OUTPUT_DIR}-baseline/findings.tsv"
BASELINE_ARG=()
if [[ -f "$BASELINE_FINDINGS_TSV" ]]; then
  BASELINE_ARG=(--baseline-findings "$BASELINE_FINDINGS_TSV")
fi
python3 "${ACTION_PATH}/bin/parse-warnings.py" "$REPORT" "$FINDINGS_TSV" \
  --sarif "$SARIF" \
  --families "${FAMILIES:-all}" \
  --version "$ACTION_VERSION" \
  "${BASELINE_ARG[@]}"

# Counts.
findings_count=$(wc -l < "$FINDINGS_TSV" | tr -d ' ')
# Column layout is 6: NEW \t SEV \t FAM \t FILE \t LINE \t TITLE.
# Severity is now $2; NEW lives in $1 ("NEW" if the finding is absent
# from the baseline, empty otherwise).
high_count=$(awk -F'\t' 'tolower($2)=="high"' "$FINDINGS_TSV" | wc -l | tr -d ' ')
medium_count=$(awk -F'\t' 'tolower($2)=="medium"' "$FINDINGS_TSV" | wc -l | tr -d ' ')
new_count=$(awk -F'\t' '$1=="NEW"' "$FINDINGS_TSV" | wc -l | tr -d ' ')

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
    # Badge sits inline with severity (no extra Δ column). Sort flips
    # NEW rows to the top so reviewers see "what did this PR add?"
    # without scanning: -s (stable, preserves the analyzer's
    # severity ordering within each group) + -r (reverse, so "NEW"
    # sorts before the empty string in column 1).
    echo "| Severity | Family | Where | What |"
    echo "|---|---|---|---|"
    sort -t $'\t' -k1,1 -s -r "$FINDINGS_TSV" | \
    while IFS=$'\t' read -r is_new sev fam fpath fline title; do
      if [[ "$fpath" == "-" || -z "$fpath" ]]; then
        where="(unresolved)"
      else
        where="\`$fpath:$fline\`"
      fi
      sev_cell="$sev"
      # shields.io style=plastic: the small, glossy variant — visible
      # enough to pop in a table cell but short enough not to blow out
      # the row height the way `for-the-badge` did.
      [[ "$is_new" == "NEW" ]] && sev_cell="$sev ![NEW](https://img.shields.io/badge/NEW-d73a4a?style=plastic)"
      echo "| $sev_cell | $fam | $where | $title |"
    done
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
  while IFS=$'\t' read -r is_new sev fam fpath fline title; do
    [[ "$fpath" == "-" || -z "$fpath" ]] && continue
    sev_lc=$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')
    level="warning"; [[ "$sev_lc" == "high" ]] && level="error"
    # Prefix new findings with [NEW] in the annotation text so the
    # Files Changed tab makes "this PR introduced this" visible inline
    # next to the diff hunk.
    new_tag=""; [[ "$is_new" == "NEW" ]] && new_tag="[NEW] "
    # Escape % \n \r for workflow commands.
    safe="$(printf '%s' "${new_tag}[$sev $fam] $title" | sed -e 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
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
        new_label=""
        (( new_count > 0 )) && new_label=" &mdash; **$new_count NEW in this PR**"
        echo "**Found $findings_count finding(s)** &mdash; $high_count high, $medium_count medium${new_label} &mdash; across **$endpoints_count** recovered endpoints."
        echo
        echo "| Severity | Family | Where | What |"
        echo "|---|---|---|---|"
        # Sort flips NEW rows to the top so reviewers see "what did
        # this PR add?" without scanning. -s preserves the analyzer's
        # severity ordering within each group; -r puts "NEW" before
        # the empty string in column 1.
        sort -t $'\t' -k1,1 -s -r "$FINDINGS_TSV" | \
        while IFS=$'\t' read -r is_new sev fam fpath fline title; do
          if [[ "$fpath" == "-" || -z "$fpath" ]]; then
            where="(unresolved)"
          else
            where="[\`$fpath:$fline\`]($REPO_URL/blob/$SHA/$fpath#L$fline)"
          fi
          # Pipe-escape the title so it doesn't break the markdown table.
          esc_title=$(printf '%s' "$title" | sed 's/|/\\|/g')
          sev_lc=$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')
          icon=":small_red_triangle:"; [[ "$sev_lc" == "medium" ]] && icon=":small_orange_diamond:"
          sev_cell="$icon $sev"
          # shields.io style=plastic — small glossy chip that doesn't
          # stretch the row height the way for-the-badge did.
          [[ "$is_new" == "NEW" ]] && sev_cell="$icon $sev ![NEW](https://img.shields.io/badge/NEW-d73a4a?style=plastic)"
          echo "| $sev_cell | $fam | $where | $esc_title |"
        done
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
