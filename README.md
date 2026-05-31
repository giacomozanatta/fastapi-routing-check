# fastapi-routing-check

A GitHub Action that statically detects **silent routing defects** in
FastAPI applications — duplicate `include_router` mounts, route
shadowing under first-match dispatch, dead handlers, cross-file
duplicate registrations, and conditional registrations on incomparable
branches — without importing or executing the application.

The action wraps `lisa-network`, a sound abstract-interpretation
analyzer for FastAPI routing, driven by the PyLiSA Python frontend.

## Usage

```yaml
- uses: <your-owner>/fastapi-routing-check@v0.1.0
  with:
    main-file: app/main.py          # required
    fail-on-finding: 'true'         # optional, default 'true'
    severity-threshold: high        # optional, default 'high'
```

A complete sample workflow is in
[`examples/routing-check.yml`](examples/routing-check.yml).

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `main-file` | yes | — | FastAPI entrypoint, relative to the repo root. |
| `project-dir` | no | `.` | Project root used as import-resolution base. |
| `output-dir` | no | `lisa-network-out` | Where `report.json` and `final-network.{txt,html,pdf}` are written. |
| `fail-on-finding` | no | `true` | Fail the job when the routing checker reports findings. |
| `severity-threshold` | no | `high` | `high` ignores medium findings for gating; `medium` fails on any finding. |
| `families` | no | `all` | Comma-separated list of finding families to surface. Findings in any other family are dropped before counts, annotations, comment, and the gate. Valid values: `duplicate-include`, `wrong-handler`, `dead-handler`, `duplicate-registration`, `conditional-registration`. Use `all` (or leave empty) to include every family. |
| `jvm-heap` | no | `4g` | `-Xmx` for the analyzer JVM. |
| `annotations` | no | `true` | Emit `::warning file=,line=::` inline annotations on the Files Changed tab. |
| `comment-on-pr` | no | `true` | Post (and update in place on reruns) a sticky PR-level comment with file:line links. Requires `pull-requests: write`. |

## Outputs

| Name | Description |
|---|---|
| `endpoints-count` | HTTP endpoints recovered. |
| `findings-count` | Total routing-checker findings. |
| `high-severity-count` | Findings at severity `high`. |
| `report-path` | Path to `report.json`. |
| `sarif-path` | Path to `results.sarif` (SARIF 2.1.0). Pipe into `github/codeql-action/upload-sarif@v3` to render findings in the PR's Code Scanning / Security tab. Emitted unconditionally (empty results array clears stale findings on the branch). |

## What gets surfaced in the PR

The action emits findings through **four** GitHub surfaces in
parallel, so the same finding is visible whichever tab the reviewer
opens:

1. **Sticky PR comment (Conversation tab).**  A single comment
   posted on the PR under the **Lisa** persona (avatar + name,
   referencing the underlying LiSA static-analysis engine) and
   edited in place on every rerun via a sentinel marker, so the
   timeline never accumulates duplicates.  Contains a markdown
   table with one row per finding — severity, family, a clickable
   `file:line` link pinned to the analysed commit, and the finding
   title.  This is the primary surface and the one most reviewers
   will land on.

   The comment body is branded as Lisa but is still technically
   authored by `github-actions[bot]` (the default
   `GITHUB_TOKEN` identity).  To have the comment authored by a
   genuine `lisa[bot]` GitHub-App identity, see
   [`docs/lisa-github-app.md`](docs/lisa-github-app.md) (TODO).
2. **Inline annotations (Files Changed tab).**  One `::warning::`
   per finding, anchored to the source file and line of the
   offending registration site, rendered as a coloured tag next to
   the diff.  GitHub silently truncates these after 10 per
   severity per workflow run, so they are best-effort; the sticky
   comment is authoritative.
3. **Job summary (Actions run page).**  The same table as the
   sticky comment, rendered at the top of the workflow run for
   maintainers reviewing the run itself.
4. **Code Scanning alerts (Security tab).**  The action always emits
   a SARIF 2.1.0 file at `${{ steps.check.outputs.sarif-path }}`.
   Pipe it into `github/codeql-action/upload-sarif@v3` (see
   [`examples/routing-check.yml`](examples/routing-check.yml)) and
   findings render natively in the PR's *Code Scanning* check and the
   repo's *Security → Code scanning alerts* view, with stable
   fingerprints so the same defect is not reported twice across
   re-runs.

   **GitHub Advanced Security requirement.**  Code Scanning is free
   on **public** repositories — the upload works out of the box.  On
   **private** repositories it requires GitHub Advanced Security
   (GHAS), which is only available on Enterprise plans for
   organisations.  Without GHAS the `upload-sarif` step returns a
   403; the example workflow uses `continue-on-error: true` so the
   job stays green, and reviewers fall back to:
   - the **sticky PR comment** + **inline annotations** (surfaces 1
     and 2 above) — both work in any repo without extra entitlements;
   - the **`results.sarif` artefact** uploaded with the rest of the
     analysis bundle — view it locally with Microsoft's
     [SARIF Viewer](https://marketplace.visualstudio.com/items?itemName=MS-SarifVSCode.sarif-viewer)
     VS Code extension or with the web viewer at
     [sarifweb.azurewebsites.net](https://sarifweb.azurewebsites.net/).

In addition, the full `report.json`, `results.sarif`,
`final-network.pdf`, and `final-network.txt` are uploaded as
workflow artefacts so reviewers can download the full topology and
the routing checker's structured output.

## Defect families detected

| Family | Severity | Trigger |
|---|---|---|
| Duplicate include | high | Same router mounted twice at the same prefix. |
| Wrong handler | high | Route shadowed by an earlier overlapping registration. |
| Dead handler | medium | Wrong-handler case where the shadowed handler is otherwise unreferenced. |
| Duplicate registration | medium | Same `(method, path)` registered in two different files. |
| Conditional registration | medium | Same path registered on incomparable `if`/`else` branches. |

## How the analyzer is shipped

The analyzer (`lisa-network` + its `pylisa` / `lisa` / `jlisa`
dependencies) is **bundled directly in this repository** under
`dist/lisa-network/`. The action invokes it through `actions/setup-java@v4`
(Amazon Corretto 23) and the launcher script at
`dist/lisa-network/bin/lisa-network`.

This makes the action self-contained: consuming workflows do not need
to pull a Docker image, authenticate against GHCR, or know anything
about the analyzer's build pipeline. Releases of the action are just
git tags on this repo; updating the analyzer means updating the
contents of `dist/lisa-network/` and cutting a new tag.

Total dist size is ~62 MB (50+ JARs); the largest single JAR is 12 MB,
well under git's per-file warning threshold.

If you ever prefer to ship the analyzer as a GHCR image instead
(useful when the dist grows beyond ~100 MB, or when you want one
analyzer source-of-truth across multiple actions), see
[`examples/optional-docker-publishing/`](examples/optional-docker-publishing/)
for a starter Dockerfile, publish workflow, and the changes the
action would need.

## Private deployment

The action repo can be kept private. Workflows in your other repos
can `uses: giacomozanatta/fastapi-routing-check@<tag>` once
*Settings → Actions → General → Access* on this repo allows it.
There is no GHCR image to authenticate against, so no `docker login`
step is required in the consuming workflow.

## Limitations

The analyzer is sound with respect to *statically visible* routing
behaviour but underapproximates in four Python patterns documented in
the underlying paper: dynamic route generation in loops over runtime
lists, reflective loading (`importlib`, `__import__`), higher-order
route registration through helper functions whose body the
interprocedural analysis cannot resolve, and route registration
through `setattr`/`eval`.  See the paper's discussion section for
detail.

## License

[TBD]
