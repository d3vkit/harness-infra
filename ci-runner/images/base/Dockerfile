# Base self-hosted GitHub Actions runner image — the stack-agnostic foundation shared
# by every harness app. Per-stack images (images/rails, images/expo, images/godot)
# `FROM` this and add their toolchain. Built once as `harness-runner:base`.
#
# Build context is ci-runner/ (so the COPY of entrypoint.sh resolves):
#   docker build -t harness-runner:base -f images/base/Dockerfile .
FROM ubuntu:24.04

# Pin the runner version; bump deliberately to the current actions/runner release so
# fresh runners don't immediately auto-update on their first job (the partial-update
# churn can crash-loop a freshly-registered runner). Refresh as new versions ship.
ARG RUNNER_VERSION=2.335.1
ENV DEBIAN_FRONTEND=noninteractive

# Runner-essential, stack-agnostic deps:
#  - actions runner runtime: libicu74 + libssl3 (load-bearing for the bundled .NET
#    host; actions/runner's installdependencies.sh has no noble candidates).
#  - tzdata: any app that boots a framework needs zoneinfo (tzinfo etc.).
#  - python3: broadly used by bin/* helper scripts.
#  - git, curl, jq, sudo, unzip: workflow + registration tooling.
#  - docker CLI: jobs talk to the paired dind daemon via DOCKER_HOST.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq git sudo unzip zip \
      tzdata python3 \
      libicu74 libssl3 \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Non-root runner user with passwordless sudo (parity with hosted runners), plus a
# writable tool cache for the setup-* actions (RUNNER_TOOL_CACHE defaults here, and
# hosted runners ship it; without it ruby/setup-ruby & friends fail with EACCES).
RUN useradd -m -s /bin/bash runner \
    && usermod -aG sudo runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && mkdir -p /opt/hostedtoolcache \
    && chown runner:runner /opt/hostedtoolcache

USER runner
WORKDIR /home/runner

# Download the runner matching the build arch (arm64 on Apple Silicon, x64 on Intel).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) RUNNER_ARCH=x64 ;; \
      arm64) RUNNER_ARCH=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    tar xzf actions-runner.tar.gz; \
    rm actions-runner.tar.gz

RUN sudo ./bin/installdependencies.sh

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
