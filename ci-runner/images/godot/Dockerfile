# Godot stack runner — used by ephemeral (Godot 4.6). riftling / terminal-ai are still stubs.
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

# Bake the Godot toolchain + the vendored GDExtensions INTO the image (VEN-1293) so CI jobs never
# download them from GitHub releases over the constrained dind->VM network at runtime — that path
# stalls/drops (`curl: (18) Transferred a partial file`) and reddened ephemeral's CI. Built ONCE here
# (arch-native, at the host Docker daemon where the network is unconstrained and the layer is cached),
# so every ephemeral runner starts with the toolchain already present. ephemeral's ci.yml then consumes
# /usr/local/bin/godot (its cache-check skips the download) and copies /opt/godot-vendor/{webrtc,twovoip}
# into the workspace instead of fetching them.
#
# Versions MUST track ephemeral: ci.yml GODOT_VERSION + justfile webrtc_version / twovoip_version. Bump
# here in lockstep — a mismatch is not fatal, it just makes ephemeral's ci.yml fall back to a (hardened)
# runtime download, which is correct but re-exposes the flake. ephemeral is the only ACTIVE godot app.
ARG GODOT_VERSION=4.6-stable
ARG WEBRTC_VERSION=1.1.0-stable
ARG TWOVOIP_VERSION=v4.2

# Hardened fetch (VEN-1293): --retry-all-errors retries the partial-file transfer drop (curl exit 18)
# that plain --retry misses; `-C -` resumes across retries so progress accumulates; NO --speed-time (it
# aborts a large asset's slow tail that curl would finish — twovoip is ~120 MB). ubuntu:24.04 ships
# curl 8.x (>= 7.71, required by --retry-all-errors). dl() rm's the target first so `-C -` starts clean.
RUN set -eux; \
    dl() { rm -f "$2"; curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 30 -C - "$1" -o "$2"; }; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) GARCH=linux.arm64 ;; \
      amd64) GARCH=linux.x86_64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    # --- Godot headless editor binary -> /usr/local/bin/godot ---
    dl "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_${GARCH}.zip" /tmp/godot.zip; \
    unzip -tq /tmp/godot.zip >/dev/null; \
    unzip -q -o /tmp/godot.zip -d /tmp/godot; \
    install -m 0755 "/tmp/godot/Godot_v${GODOT_VERSION}_${GARCH}" /usr/local/bin/godot; \
    # --- webrtc-native GDExtension -> /opt/godot-vendor/webrtc (mirrors `just fetch-webrtc`) ---
    mkdir -p /opt/godot-vendor; \
    dl "https://github.com/godotengine/webrtc-native/releases/download/${WEBRTC_VERSION}/godot-extension-webrtc.zip" /tmp/webrtc.zip; \
    unzip -tq /tmp/webrtc.zip >/dev/null; \
    unzip -q -o /tmp/webrtc.zip -d /opt/godot-vendor; \
    # --- twovoip Opus GDExtension -> /opt/godot-vendor/twovoip (mirrors `just fetch-twovoip`) ---
    dl "https://github.com/goatchurchprime/two-voip-godot-4/releases/download/${TWOVOIP_VERSION}/TwoVoIP${TWOVOIP_VERSION}.zip" /tmp/twovoip.zip; \
    unzip -tq /tmp/twovoip.zip >/dev/null; \
    unzip -q -o /tmp/twovoip.zip "project/addons/twovoip/*" -d /tmp/twovoip-fetch; \
    mv /tmp/twovoip-fetch/project/addons/twovoip /opt/godot-vendor/twovoip; \
    chmod -R a+rX /opt/godot-vendor; \
    rm -rf /tmp/godot.zip /tmp/godot /tmp/webrtc.zip /tmp/twovoip.zip /tmp/twovoip-fetch; \
    # Build-time smoke test: the baked binary loads headless (matches ephemeral ci.yml's `godot --version`).
    godot --version

USER runner
