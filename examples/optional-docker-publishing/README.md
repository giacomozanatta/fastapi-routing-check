# Optional: publish the analyzer as a Docker image

The default `fastapi-routing-check` action **bundles the analyzer JARs
directly in this repository** (under `dist/lisa-network/`) and invokes
them via JVM, so consuming workflows need nothing except
`actions/setup-java@v4` (which the action does itself).

The files in this directory exist for a possible alternative
deployment, where the analyzer is shipped as a container image on
GHCR and the action `docker pull`s it at run time. Reasons to switch:

* The action repo's size keeps growing as the analyzer accumulates
  features and dependencies, and you want to keep the action repo small.
* You're already publishing container images of the analyzer for
  non-Action consumers (e.g.\ the corpus evaluation pipeline) and want
  one source of truth.
* You want to consume the same analyzer from multiple actions / tools.

In that case:

1. Drop [`Dockerfile`](Dockerfile) into the `lisa-network` repo at
   `docker/Dockerfile.publish` (it coexists with the existing
   bind-mount Dockerfile used for corpus runs).
2. Drop [`publish-image.yml`](publish-image.yml) at
   `.github/workflows/publish-image.yml` in the same repo. Cutting a
   tagged release builds and pushes
   `ghcr.io/<owner>/lisa-network:{latest,<sha>,<tag>}`.
3. Edit this action's `action.yml`: add back an `analyzer-image`
   input, restore the `docker pull` step, and have `entrypoint.sh`
   `docker run` the image instead of invoking the bundled launcher.
4. Optionally delete `dist/lisa-network/` from this repo to reclaim
   the space; the action becomes a thin shim that pulls and runs.

Until that switch is needed, the bundled-JAR approach keeps the
action self-contained and removes the GHCR publish step from the
release path.
