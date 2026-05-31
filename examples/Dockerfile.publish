# Publishable analyzer image for the FastAPI routing-check action.
#
# Drop this at docker/Dockerfile.publish inside the lisa-network repo
# (alongside the existing bind-mount Dockerfile, which it does NOT
# replace — the existing one stays the right tool for corpus eval runs
# against a host-mounted working copy).
#
# This variant bakes the four sibling repos in at build time, so the
# resulting image runs standalone:
#   docker run --rm -v "$PWD":/workspace -w /workspace \
#     ghcr.io/<owner>/lisa-network:<tag> \
#     --main-file app/main.py --project-dir . --output-dir out --no-cfg-dump
#
# Build (from the lisa-network repo root):
#   docker build -f docker/Dockerfile.publish -t lisa-network:dev .
#
# Set these as --build-arg values to pin sibling-repo revisions on
# release builds; defaults follow the head of the main branches.

# ============================================================
# Stage 1 — build the four repos with Gradle
# ============================================================
FROM amazoncorretto:23 AS build

ARG LISA_REPO=https://github.com/lisa-analyzer/lisa.git
ARG LISA_REF=main
ARG PYLISA_REPO=https://github.com/lisa-analyzer/pylisa.git
ARG PYLISA_REF=main
ARG JLISA_REPO=https://github.com/lisa-analyzer/jlisa.git
ARG JLISA_REF=main

RUN dnf install -y git tar gzip xz unzip which procps-ng diffutils findutils \
 && dnf clean all

WORKDIR /src

# Clone siblings at the requested refs.
RUN git clone --depth 1 --branch "$LISA_REF"   "$LISA_REPO"   lisa   \
 && git clone --depth 1 --branch "$PYLISA_REF" "$PYLISA_REPO" pylisa \
 && git clone --depth 1 --branch "$JLISA_REF"  "$JLISA_REPO"  jlisa

# Publish the three deps to the local Maven repo (resolved by
# lisa-network's build.gradle.kts via mavenLocal()).
RUN cd lisa   && ./gradlew --no-daemon publishToMavenLocal -x test \
 && cd ../jlisa && ./gradlew --no-daemon publishToMavenLocal -x test \
 && cd ../pylisa && ./gradlew --no-daemon publishToMavenLocal -x test

# Build lisa-network itself from the build context (this Dockerfile lives
# at docker/Dockerfile.publish inside the lisa-network repo, so the
# context root IS the lisa-network source).
COPY . /src/lisa-network
RUN cd /src/lisa-network && ./gradlew --no-daemon installDist -x test

# ============================================================
# Stage 2 — slim runtime
# ============================================================
FROM amazoncorretto:23

RUN dnf install -y jq python3 \
 && dnf clean all

# Bring in the assembled distribution. The Gradle `application` plugin
# produces a self-contained bin/ + lib/ tree under build/install/<name>.
COPY --from=build /src/lisa-network/build/install/lisa-network /opt/lisa-network

WORKDIR /workspace
ENV JAVA_HOME=/usr/lib/jvm/java-23-amazon-corretto \
    PATH="/opt/lisa-network/bin:${PATH}"

# Default entrypoint = the analyzer CLI itself. The action overrides this
# explicitly in entrypoint.sh, so consumers can still `docker run` the
# image and pass any of the supported flags directly.
ENTRYPOINT ["/opt/lisa-network/bin/lisa-network"]
CMD ["--help"]
