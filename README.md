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
| `analyzer-image` | no | `ghcr.io/anonymous/lisa-network:latest` | Container image of the analyzer. Pin to a release tag in production. |
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

## What gets surfaced in the PR

The action emits findings through **three** GitHub surfaces in
parallel, so the same finding is visible whichever tab the reviewer
opens:

1. **Sticky PR comment (Conversation tab).**  A single comment
   posted on the PR (and edited in place on every rerun, via a
   sentinel marker, so the timeline never accumulates duplicates).
   Contains a markdown table with one row per finding —
   severity, family, a clickable `file:line` link pinned to the
   commit being analysed, and the finding title.  This is the
   primary surface and the one most reviewers will land on.
2. **Inline annotations (Files Changed tab).**  One `::warning::`
   per finding, anchored to the source file and line of the
   offending registration site, rendered as a coloured tag next to
   the diff.  GitHub silently truncates these after 10 per
   severity per workflow run, so they are best-effort; the sticky
   comment is authoritative.
3. **Job summary (Actions run page).**  The same table as the
   sticky comment, rendered at the top of the workflow run for
   maintainers reviewing the run itself.

In addition, the full `report.json`, `final-network.html`, and
`final-network.txt` are uploaded as workflow artefacts so reviewers
can download the full topology and the routing checker's structured
output.

## Defect families detected

| Family | Severity | Trigger |
|---|---|---|
| Duplicate include | high | Same router mounted twice at the same prefix. |
| Wrong handler | high | Route shadowed by an earlier overlapping registration. |
| Dead handler | medium | Wrong-handler case where the shadowed handler is otherwise unreferenced. |
| Duplicate registration | medium | Same `(method, path)` registered in two different files. |
| Conditional registration | medium | Same path registered on incomparable `if`/`else` branches. |

## Visibility / private repos

The action and the analyzer image can both be kept private. See the
README section *"Private deployment"* below; in short, the analyzer
image is pulled with `${{ secrets.GITHUB_TOKEN }}` when the package is
in a private GHCR repo with the consuming repo granted access.

## Setting up the analyzer image

This action does **not** ship the analyzer binary in the action repo
itself; it pulls a pre-built container image (default
`ghcr.io/anonymous/lisa-network:latest`).  To publish your own:

1. Copy [`examples/Dockerfile.publish`](examples/Dockerfile.publish)
   into the `lisa-network` repo at `docker/Dockerfile.publish` —
   alongside, not replacing, the existing bind-mount Dockerfile that
   the corpus evaluation runs use.
2. Copy
   [`examples/publish-analyzer-image.yml`](examples/publish-analyzer-image.yml)
   into the same repo at `.github/workflows/publish-image.yml`.
3. Cut a tagged release on the `lisa-network` repo. The workflow
   builds and pushes
   `ghcr.io/<owner>/lisa-network:{latest,<sha>,<tag>}`.
4. Point the consuming workflow at it via the `analyzer-image` input.

The publishable Dockerfile clones the three sibling repos (`lisa`,
`pylisa`, `jlisa`) at build time and publishes them to the build
container's local Maven cache, so the final image is self-contained
and the consuming workflow needs no awareness of the sibling-repo
layout.

## Private deployment

To run this action and the analyzer image entirely inside your
organisation:

* Keep this action's repo private. Workflows in the same
  organisation can `uses: <org>/fastapi-routing-check@<sha>` once
  *Settings → Actions → General → Access* allows it.
* Push the analyzer image to a private GHCR package and grant the
  consuming repo *Manage Actions access*. The sample workflow's
  `docker/login-action@v3` step handles authentication via
  `${{ secrets.GITHUB_TOKEN }}`.

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
