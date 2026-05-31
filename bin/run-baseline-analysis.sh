#!/usr/bin/env bash
# Run the analyzer against the PR's merge-base SHA so the endpoint-delta
# step has a baseline endpoints.tsv to diff the head's against.
#
# Invoked by action.yml's "Analyse merge-base (cache miss)" composite step.
# Required env (set by the caller):
#   MAIN_FILE         entrypoint path, relative to repo root
#   PROJECT_DIR       project root passed to the analyzer
#   OUTPUT_DIR        head output dir; the baseline is written to
#                     ${OUTPUT_DIR}-baseline (sibling, never overlaps the
#                     head analysis output)
#   JVM_HEAP          -Xmx for the analyzer JVM
#   ACTION_PATH       absolute path to this action's checkout
#   MERGE_BASE_SHA    commit SHA to analyse (resolved by the merge-base step)
#
# Design notes:
#  - git worktree (not git stash / git checkout) keeps $GITHUB_WORKSPACE
#    untouched, so the head analysis below runs against the unchanged
#    PR tree without us having to dance with stash/pop.
#  - We need two artefacts from the baseline run: endpoints.tsv (for the
#    endpoint-delta diff) and findings.tsv (so the head's parse-warnings
#    can mark each finding as NEW vs already-on-baseline). report.json
#    is parsed transiently — only the two TSVs survive into the cache.
#    final-network.pdf, .html, .mmd, and the SARIF are head-only concerns.
#    Trimming to the two TSVs keeps the cache entry small (~20–200 KB).
#  - Failure mode: if the merge-base SHA predates the project layout
#    that --main-file refers to (e.g., src/dispatch/main.py only exists
#    in newer commits), the analyzer will error. We exit 0 anyway so the
#    head analysis still runs; the delta step will treat the missing
#    baseline as "first run, no baseline" and skip the diff cleanly.
set -uo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
ANALYZER="${ACTION_PATH}/dist/lisa-network/bin/lisa-network"
BASELINE_OUT="${WORKSPACE}/${OUTPUT_DIR}-baseline"
WORKTREE_DIR="$(mktemp -d -t lisa-baseline.XXXXXX)"

mkdir -p "$BASELINE_OUT"

cleanup() {
  # --force tolerates analyzer-leftover files inside the worktree; we
  # never want a worktree-removal failure to fail the step.
  git -C "$WORKSPACE" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  rm -rf "$WORKTREE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> checking out merge-base ${MERGE_BASE_SHA} into ${WORKTREE_DIR}"
if ! git -C "$WORKSPACE" worktree add --detach "$WORKTREE_DIR" "$MERGE_BASE_SHA" 2>&1; then
  echo "::warning::Could not check out merge-base ${MERGE_BASE_SHA} (commit may not be in shallow clone). Skipping baseline analysis."
  exit 0
fi

echo "==> running analyzer against merge-base"
# Run from inside the worktree so --main-file resolves correctly.
(
  cd "$WORKTREE_DIR"
  JAVA_TOOL_OPTIONS="-Xmx${JVM_HEAP}" \
    "$ANALYZER" \
      --main-file   "$MAIN_FILE" \
      --project-dir "$PROJECT_DIR" \
      --output-dir  "$BASELINE_OUT" \
      --no-cfg-dump
) || {
  # Analyzer failure on the baseline is non-fatal — head analysis still
  # runs and the delta step treats a missing/empty baseline endpoints.tsv
  # as "first run, no baseline" (status=ok, totals all zero).
  echo "::warning::Baseline analyzer run failed against ${MERGE_BASE_SHA}; head analysis will proceed without a delta."
  exit 0
}

BASELINE_FINAL_TXT="${BASELINE_OUT}/final-network.txt"
BASELINE_REPORT="${BASELINE_OUT}/report.json"
BASELINE_ENDPOINTS_TSV="${BASELINE_OUT}/endpoints.tsv"
BASELINE_FINDINGS_TSV="${BASELINE_OUT}/findings.tsv"

if [[ ! -f "$BASELINE_FINAL_TXT" ]]; then
  echo "::warning::Baseline analyzer did not produce final-network.txt; delta will be skipped."
  : > "$BASELINE_ENDPOINTS_TSV"
  : > "$BASELINE_FINDINGS_TSV"
  exit 0
fi

echo "==> extracting baseline endpoints"
python3 "${ACTION_PATH}/bin/parse-endpoints.py" "$BASELINE_FINAL_TXT" "$BASELINE_ENDPOINTS_TSV"

# Findings parsing is best-effort: a baseline run that produced
# final-network.txt may still lack report.json on edge cases. Touch an
# empty file so the head's parse-warnings.py treats it as "no baseline
# findings" (every head finding marked NEW) rather than crashing.
if [[ -f "$BASELINE_REPORT" ]]; then
  echo "==> extracting baseline findings"
  python3 "${ACTION_PATH}/bin/parse-warnings.py" "$BASELINE_REPORT" "$BASELINE_FINDINGS_TSV" \
    --families "${FAMILIES:-all}" \
    --version baseline
else
  echo "::warning::Baseline run produced no report.json; head findings will all be classified as NEW."
  : > "$BASELINE_FINDINGS_TSV"
fi

# Trim the cached payload to the two TSVs the head needs. Cache entries
# this small (~20–200 KB) keep us well below GitHub's 10 GB-per-repo
# limit even at hundreds of distinct merge-bases.
find "$BASELINE_OUT" -mindepth 1 \
  -not -name 'endpoints.tsv' -not -name 'findings.tsv' \
  -not -path "${BASELINE_OUT}" -exec rm -rf {} + 2>/dev/null || true

echo "==> baseline cache populated: $(wc -l < "$BASELINE_ENDPOINTS_TSV" | tr -d ' ') endpoints, $(wc -l < "$BASELINE_FINDINGS_TSV" | tr -d ' ') findings"
