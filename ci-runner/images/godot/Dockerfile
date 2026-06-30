# Godot stack runner — used by riftling, terminal-ai.
#
# STUB — fill in the Godot editor + export templates matching the apps' Godot
# version, then validate against their .github/workflows before relying on it.
#
#   docker build -t harness-runner:godot --build-arg BASE_IMAGE=harness-runner:base \
#     -f images/godot/Dockerfile .
ARG BASE_IMAGE=harness-runner:base
FROM ${BASE_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

# TODO(godot): download the headless Godot editor + matching export templates for the
#   apps' GODOT_VERSION into /usr/local/bin, plus any export/runtime libs the CI needs
#   (e.g. headless rendering libs). Example skeleton (uncomment + adjust):
#   ARG GODOT_VERSION=4.3
#   RUN curl -fsSL -o godot.zip "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
#     && unzip godot.zip -d /usr/local/bin && ... export templates ...

USER runner
