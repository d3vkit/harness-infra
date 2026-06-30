# Expo / React Native stack runner — used by cooldown.
#
# STUB — fill in the toolchain Expo CI needs, then validate against cooldown's
# .github/workflows before relying on it. Most Expo CI (lint, type-check, jest, EAS
# submit) needs just Node + a package manager; native Android builds additionally
# need the Android SDK + platform-tools (large — only add if CI actually runs them).
#
#   docker build -t harness-runner:expo --build-arg BASE_IMAGE=harness-runner:base \
#     -f images/expo/Dockerfile .
ARG BASE_IMAGE=harness-runner:base
FROM ${BASE_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# TODO(expo): pin the Node version cooldown's CI uses (e.g. install from NodeSource,
#   or drop a Node tarball into /opt/hostedtoolcache so actions/setup-node finds it
#   offline), then add the package manager (npm/yarn/pnpm) and watchman. Add the
#   Android SDK + platform-tools ONLY if CI runs native Android builds.
# Example skeleton (uncomment + adjust):
#   ARG NODE_VERSION=20.11.1
#   RUN ... install node ${NODE_VERSION} ...
#   RUN npm i -g yarn pnpm && apt-get install -y --no-install-recommends watchman

USER runner
